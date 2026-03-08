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

        // Use a plain DispatchQueue thread — NOT a Swift async Task.
        // DispatchSemaphore.wait() inside Task starves the cooperative thread pool
        // (pool size ≈ CPU core count), causing NWConnection send-completions to
        // never fire → deadlock → browser gets "Failed to fetch".
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: resolve PHAsset → file URL (callback-based, no await needed)
            let avSem = DispatchSemaphore(value: 0)
            var fileURL: URL?
            let avOpts = PHVideoRequestOptions()
            avOpts.isNetworkAccessAllowed = false
            avOpts.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset.phAsset, options: avOpts) { avAsset, _, _ in
                fileURL = (avAsset as? AVURLAsset)?.url
                avSem.signal()
            }
            avSem.wait()

            guard let url = fileURL else {
                self.send(.notFound(), on: connection, completion: completion)
                return
            }

            // Step 2: open file
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileHandle = try? FileHandle(forReadingFrom: url) else {
                self.send(.notFound(), on: connection, completion: completion)
                return
            }
            defer { try? fileHandle.close() }
            let fileSize = attrs[.size] as? Int64 ?? 0

            // Step 3: resolve Range
            let statusCode: Int
            let statusText: String
            let startByte: Int64
            let sendLength: Int64
            if let range = request.rangeHeader {
                startByte  = range.start
                sendLength = (range.end ?? (fileSize - 1)) - range.start + 1
                statusCode = 206; statusText = "Partial Content"
            } else {
                startByte  = 0
                sendLength = fileSize
                statusCode = 200; statusText = "OK"
            }

            // Step 4: build and send response headers
            let ext = url.pathExtension.lowercased()
            let contentType = ext == "mov" ? "video/quicktime" : "video/mp4"
            var hdrs: [String: String] = [
                "Content-Type": contentType,
                "Content-Length": "\(sendLength)",
                "Content-Disposition": "attachment; filename=\"\(asset.filename)\"",
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
                "Connection": "close"
            ]
            if statusCode == 206 {
                hdrs["Content-Range"] = "bytes \(startByte)-\(startByte + sendLength - 1)/\(fileSize)"
            }
            let headerData = HTTPResponse(statusCode: statusCode, statusText: statusText,
                                         headers: hdrs, body: Data()).headerData()
            let headerSem = DispatchSemaphore(value: 0)
            connection.send(content: headerData, completion: .contentProcessed { _ in headerSem.signal() })
            headerSem.wait()

            // Step 5: stream file body in 256 KB chunks
            guard (try? fileHandle.seek(toOffset: UInt64(startByte))) != nil else {
                connection.cancel(); completion(); return
            }
            let chunkSize = 256 * 1024
            var remaining = sendLength
            while remaining > 0 {
                let toRead = Int(min(Int64(chunkSize), remaining))
                let chunk  = fileHandle.readData(ofLength: toRead)
                guard !chunk.isEmpty else { break }
                remaining -= Int64(chunk.count)
                let chunkSem = DispatchSemaphore(value: 0)
                connection.send(content: chunk, completion: .contentProcessed { _ in chunkSem.signal() })
                chunkSem.wait()
            }
            connection.cancel()
            completion()
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
