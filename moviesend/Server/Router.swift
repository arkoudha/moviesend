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
        var data: Data?
        Task { data = await PhotosService.getThumbnail(for: asset.phAsset); sem.signal() }
        sem.wait()
        guard let d = data else { return .notFound() }
        return .ok(body: d, contentType: "image/jpeg")
    }

    // MARK: - Video download (streaming)

    private func handleDownload(request: HTTPRequest, connection: NWConnection, completion: @escaping () -> Void) {
        guard let assetId = extractVideoId(from: request.path),
              let asset = videoCache.first(where: { $0.id == assetId }) else {
            send(.notFound(), on: connection, completion: completion)
            return
        }

        Task {
            do {
                let urlAsset = try await PhotosService.getAVURLAsset(for: asset.phAsset)
                let fileURL = urlAsset.url
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attrs[.size] as? Int64 ?? 0

                guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
                    self.send(.notFound(), on: connection, completion: completion)
                    return
                }
                defer { try? fileHandle.close() }

                // Parse Range header
                let (statusCode, statusText, startByte, sendLength): (Int, String, Int64, Int64)
                if let range = request.rangeHeader {
                    let s = range.start
                    let e = range.end ?? (fileSize - 1)
                    startByte  = s
                    sendLength = e - s + 1
                    statusCode = 206; statusText = "Partial Content"
                } else {
                    startByte  = 0
                    sendLength = fileSize
                    statusCode = 200; statusText = "OK"
                }

                let ext = fileURL.pathExtension.lowercased()
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
                    let end = startByte + sendLength - 1
                    hdrs["Content-Range"] = "bytes \(startByte)-\(end)/\(fileSize)"
                }
                let headerResp = HTTPResponse(statusCode: statusCode, statusText: statusText,
                                             headers: hdrs, body: Data())
                let headerData = headerResp.headerData()

                // Send headers, then stream body in 256 KB chunks
                let headerSent = DispatchSemaphore(value: 0)
                connection.send(content: headerData, completion: .contentProcessed { _ in headerSent.signal() })
                headerSent.wait()

                try fileHandle.seek(toOffset: UInt64(startByte))
                let chunkSize = 256 * 1024
                var remaining = sendLength
                while remaining > 0 {
                    let toRead = Int(min(Int64(chunkSize), remaining))
                    let chunk = fileHandle.readData(ofLength: toRead)
                    guard !chunk.isEmpty else { break }
                    remaining -= Int64(chunk.count)
                    let chunkSent = DispatchSemaphore(value: 0)
                    connection.send(content: chunk, completion: .contentProcessed { _ in chunkSent.signal() })
                    chunkSent.wait()
                }
                connection.cancel()
                completion()
            } catch {
                self.send(.notFound(), on: connection, completion: completion)
            }
        }
    }

    // MARK: - Static Web UI

    private func handleStatic(request: HTTPRequest) -> HTTPResponse {
        let filePath = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        guard !filePath.contains("..") else { return .forbidden() }

        guard let webUIDir = Bundle.main.url(forResource: "WebUI", withExtension: nil),
              let data = try? Data(contentsOf: webUIDir.appendingPathComponent(filePath)) else {
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
