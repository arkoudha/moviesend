import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let queryParams: [String: String]
    let cookies: [String: String]

    static func parse(from data: Data) -> HTTPRequest? {
        // Find \r\n\r\n separator between headers and body
        let sep: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var headerEnd = -1
        if data.count >= 4 {
            for i in 0...(data.count - 4) {
                if data[i] == sep[0] && data[i+1] == sep[1] &&
                   data[i+2] == sep[2] && data[i+3] == sep[3] {
                    headerEnd = i
                    break
                }
            }
        }

        let headerData = headerEnd >= 0 ? data.prefix(headerEnd) : data
        let rawBody   = headerEnd >= 0 ? data.dropFirst(headerEnd + 4) : Data()

        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method   = parts[0]
        let fullPath = parts[1]

        // Parse path + query string
        var path = fullPath
        var queryParams: [String: String] = [:]
        if let qi = fullPath.firstIndex(of: "?") {
            path = String(fullPath[fullPath.startIndex..<qi])
            let qs = String(fullPath[fullPath.index(after: qi)...])
            for pair in qs.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count >= 2 {
                    let key = kv[0].removingPercentEncoding ?? kv[0]
                    let val = kv[1...].joined(separator: "=").removingPercentEncoding ?? kv[1]
                    queryParams[key] = val
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let ci = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<ci]).trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        // Parse cookies
        var cookies: [String: String] = [:]
        if let cookieHeader = headers["cookie"] {
            for pair in cookieHeader.components(separatedBy: "; ") {
                let kv = pair.components(separatedBy: "=")
                if kv.count >= 2 {
                    cookies[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1...].joined(separator: "=")
                }
            }
        }

        // Honour Content-Length for body
        let body: Data
        if let cls = headers["content-length"], let cl = Int(cls) {
            body = Data(rawBody.prefix(cl))
        } else {
            body = Data(rawBody)
        }

        return HTTPRequest(method: method, path: path, headers: headers,
                           body: body, queryParams: queryParams, cookies: cookies)
    }

    /// Extracts session token from Cookie, query param, or header
    var sessionToken: String? {
        cookies["session"] ?? queryParams["token"] ?? headers["x-session-token"]
    }

    /// Parses Range: bytes=start-end header
    var rangeHeader: (start: Int64, end: Int64?)? {
        guard let r = headers["range"], r.hasPrefix("bytes=") else { return nil }
        let parts = String(r.dropFirst(6)).components(separatedBy: "-")
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? nil : Int64(parts[1])
        return (start, end)
    }
}
