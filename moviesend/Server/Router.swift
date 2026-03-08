import Foundation
import Network
import Photos

/// Routes incoming HTTP requests to the appropriate handler.
/// Handlers that need to stream large bodies write directly to the NWConnection.
final class Router {
    private let sessionManager: SessionManager
    private let pinManager: PINManager
    private var videoCache: [VideoAsset] = []

    /// Called on the main queue when a PC successfully authenticates.
    var onAuthenticated: (() -> Void)?

    init(sessionManager: SessionManager, pinManager: PINManager) {
        self.sessionManager = sessionManager
        self.pinManager = pinManager
    }

    func updateVideoCache(_ videos: [VideoAsset]) {
        videoCache = videos
    }

    // MARK: - Dispatch

    func handle(request: HTTPRequest, connection: NWConnection, completion: @escaping () -> Void) {
        let response: HTTPResponse?

        switch (request.method, request.path) {
        case ("POST", "/api/auth"):
            response = handleAuth(request: request)
        case ("GET", "/api/videos"):
            response = authenticated(request) { self.handleVideoList() }
        case ("GET", "/api/status"):
            response = authenticated(request) { self.handleStatus() }
        case ("GET", let p) where p.hasPrefix("/api/videos/") && p.hasSuffix("/thumbnail"):
            response = authenticated(request) { self.handleThumbnail(request: request) }
        case ("GET", let p) where p.hasPrefix("/api/videos/") && p.hasSuffix("/download"):
            // Streaming download — handler writes directly and calls completion
            if let tok = request.sessionToken, sessionManager.validate(token: tok) {
                handleDownload(request: request, connection: connection, completion: completion)
            } else {
                send(.forbidden(), on: connection, completion: completion)
            }
            return
        case ("OPTIONS", _):
            response = cors()
        case ("GET", _):
            response = handleStatic(request: request)
        default:
            response = .notFound()
        }

        if let r = response {
            send(r, on: connection, completion: completion)
        }
    }

    // MARK: - Auth

    private func handleAuth(request: HTTPRequest) -> HTTPResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: String],
              let pin = obj["pin"] else {
            return .badRequest("Missing pin")
        }
        if pinManager.verify(pin) {
            let tok = sessionManager.token
            let body = try! JSONSerialization.data(withJSONObject: ["success": true, "token": tok])
            let cookie = "session=\(tok); Path=/; HttpOnly; SameSite=Strict"
            DispatchQueue.main.async { self.onAuthenticated?() }
            return .ok(body: body, contentType: "application/json", extra: ["Set-Cookie": cookie])
        } else {
            let body = try! JSONSerialization.data(withJSONObject: ["success": false, "error": "Invalid PIN"])
            return HTTPResponse(statusCode: 401, statusText: "Unauthorized",
                                headers: ["Content-Type": "application/json", "Content-Length": "\(body.count)"],
                                body: body)
        }
    }

    // MARK: - API

    private func handleVideoList() -> HTTPResponse {
        let dicts = videoCache.map { $0.toDictionary() }
        return .json(["videos": dicts, "total": dicts.count])
    }

    private func handleStatus() -> HTTPResponse {
        let fmt = ISO8601DateFormatter()
        return .json([
            "status": "running",
            "serverVersion": "1.0.0",
            "sessionExpiry": fmt.string(from: sessionManager.expiry)
        ])
    }

    private func handleThumbnail(request: HTTPRequest) -> HTTPResponse {
        guard let assetId = extractVideoId(from: request.path),
              let asset = videoCache.first(where: { $0.id == assetId }) else {
            return .notFound()
        }
        let sem = DispatchSemaphore(value: 0)
        var thumbnailData: Data?
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.isNetworkAccessAllowed = false
        opts.isSynchronous = false
        // Use PHImageManager directly (no Task) to avoid cooperative-thread-pool/semaphore deadlock
        PHImageManager.default().requestImage(
            for: asset.phAsset,
            targetSize: CGSize(width: 240, height: 240),
            contentMode: .aspectFill,
            options: opts
        ) { image, _ in
            thumbnailData = image?.jpegData(compressionQuality: 0.75)
            sem.signal()
        }
        sem.wait()
        guard let data = thumbnailData else { return .notFound() }
        return .ok(body: data, contentType: "image/jpeg")
    }

    // MARK: - Video download (streaming)

    private func handleDownload(request: HTTPRequest, connection: NWConnection, completion: @escaping () -> Void) {
        guard let assetId = extractVideoId(from: request.path),
              let asset = videoCache.first(where: { $0.id == assetId }) else {
            send(.notFound(), on: connection, completion: completion)
            return
        }

        // Run on a dedicated background thread so DispatchSemaphore.wait() is safe.
        DispatchQueue.global(qos: .userInitiated).async {
            // Use PHAssetResource directly — avoids requestAVAsset which can return
            // AVCompositionItem (not AVURLAsset) for HEVC/edited videos, causing nil URL.
            let resources = PHAssetResource.assetResources(for: asset.phAsset)
            guard let resource = resources.first(where: { $0.type == .video }) else {
                self.send(.notFound(), on: connection, completion: completion)
                return
            }

            // File size from resource metadata (same source used when building video list)
            let fileSize: Int64 = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
                                  ?? asset.size
            let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
            let contentType = ext == "mp4" ? "video/mp4" : "video/quicktime"

            // Send response headers
            let hdrs: [String: String] = [
                "Content-Type":        contentType,
                "Content-Length":      "\(fileSize)",
                "Content-Disposition": "attachment; filename=\"\(resource.originalFilename)\"",
                "Accept-Ranges":       "bytes",
                "Access-Control-Allow-Origin": "*",
                "Connection":          "close"
            ]
            let headerResp = HTTPResponse(statusCode: 200, statusText: "OK",
                                          headers: hdrs, body: Data())
            let headerSem = DispatchSemaphore(value: 0)
            connection.send(content: headerResp.headerData(),
                            completion: .contentProcessed { _ in headerSem.signal() })
            headerSem.wait()

            // Stream video bytes via PHAssetResourceManager.
            // dataReceivedHandler runs on Photos' internal serial queue — blocking it
            // here with a semaphore provides natural backpressure (one chunk in flight
            // at a time) and is safe because NWConnection fires completions on its own
            // queue (separate from Photos' queue).
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = false

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: opts,
                dataReceivedHandler: { data in
                    let chunkSem = DispatchSemaphore(value: 0)
                    connection.send(content: data,
                                    completion: .contentProcessed { _ in chunkSem.signal() })
                    chunkSem.wait()
                },
                completionHandler: { _ in
                    connection.cancel()
                    completion()
                }
            )
        }
    }

    // MARK: - Static Web UI

    private func handleStatic(request: HTTPRequest) -> HTTPResponse {
        let filePath = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        guard !filePath.contains("..") else { return .forbidden() }

        // Folder references are copied to the bundle root — access via bundleURL, not url(forResource:)
        let webUIDir = Bundle.main.bundleURL.appendingPathComponent("WebUI")
        guard let data = try? Data(contentsOf: webUIDir.appendingPathComponent(filePath)) else {
            return .notFound()
        }
        let ext = URL(fileURLWithPath: filePath).pathExtension
        let ct: String
        switch ext {
        case "html": ct = "text/html; charset=utf-8"
        case "css":  ct = "text/css"
        case "js":   ct = "application/javascript"
        default:     ct = "application/octet-stream"
        }
        return .ok(body: data, contentType: ct)
    }

    // MARK: - Helpers

    private func authenticated(_ req: HTTPRequest, handler: () -> HTTPResponse) -> HTTPResponse {
        guard let tok = req.sessionToken, sessionManager.validate(token: tok) else {
            return .forbidden()
        }
        return handler()
    }

    private func cors() -> HTTPResponse {
        HTTPResponse(statusCode: 204, statusText: "No Content",
                     headers: ["Access-Control-Allow-Origin": "*",
                                "Access-Control-Allow-Headers": "X-Session-Token, Content-Type",
                                "Content-Length": "0"],
                     body: Data())
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection, completion: @escaping () -> Void) {
        var r = response
        r.headers["Access-Control-Allow-Origin"] = "*"
        r.headers["Connection"] = "close"
        connection.send(content: r.toData(), completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private func extractVideoId(from path: String) -> String? {
        // /api/videos/{id}/thumbnail  or  /api/videos/{id}/download
        let components = path.components(separatedBy: "/")
        guard components.count >= 4 else { return nil }
        return components[3].removingPercentEncoding
    }
}
