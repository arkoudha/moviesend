import Foundation

struct HTTPResponse {
    let statusCode: Int
    let statusText: String
    var headers: [String: String]
    let body: Data

    // MARK: - Factory methods

    static func ok(body: Data, contentType: String, extra: [String: String] = [:]) -> HTTPResponse {
        var h = ["Content-Type": contentType, "Content-Length": "\(body.count)"]
        h.merge(extra) { _, new in new }
        return HTTPResponse(statusCode: 200, statusText: "OK", headers: h, body: body)
    }

    static func json(_ object: Any, extra: [String: String] = [:]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return ok(body: data, contentType: "application/json; charset=utf-8", extra: extra)
    }

    static func html(_ string: String) -> HTTPResponse {
        let data = string.data(using: .utf8)!
        return ok(body: data, contentType: "text/html; charset=utf-8")
    }

    static func forbidden() -> HTTPResponse {
        let body = "403 Forbidden".data(using: .utf8)!
        return HTTPResponse(statusCode: 403, statusText: "Forbidden",
                            headers: ["Content-Type": "text/plain", "Content-Length": "\(body.count)"],
                            body: body)
    }

    static func notFound() -> HTTPResponse {
        let body = "404 Not Found".data(using: .utf8)!
        return HTTPResponse(statusCode: 404, statusText: "Not Found",
                            headers: ["Content-Type": "text/plain", "Content-Length": "\(body.count)"],
                            body: body)
    }

    static func badRequest(_ msg: String = "Bad Request") -> HTTPResponse {
        let body = msg.data(using: .utf8)!
        return HTTPResponse(statusCode: 400, statusText: "Bad Request",
                            headers: ["Content-Type": "text/plain", "Content-Length": "\(body.count)"],
                            body: body)
    }

    static func unauthorized(_ msg: String = "Unauthorized") -> HTTPResponse {
        let body = msg.data(using: .utf8)!
        return HTTPResponse(statusCode: 401, statusText: "Unauthorized",
                            headers: ["Content-Type": "text/plain", "Content-Length": "\(body.count)"],
                            body: body)
    }

    // MARK: - Serialisation

    /// Serialises the full HTTP/1.1 response to Data (headers + body)
    func toData() -> Data {
        var res = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (k, v) in headers { res += "\(k): \(v)\r\n" }
        res += "\r\n"
        var data = res.data(using: .utf8)!
        data.append(body)
        return data
    }

    /// Serialises only the header section (for streaming responses)
    func headerData() -> Data {
        var res = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (k, v) in headers { res += "\(k): \(v)\r\n" }
        res += "\r\n"
        return res.data(using: .utf8)!
    }
}
