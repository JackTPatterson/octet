import Foundation

/// A parsed HTTP/1.1 request. Only what the phone host needs: a fixed-length
/// body, no chunked uploads, one request per connection.
struct PhoneHTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// The token after `Bearer `, if the request carries one.
    var bearerToken: String? {
        guard let value = header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

struct PhoneHTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> PhoneHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return PhoneHTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func empty(_ status: Int) -> PhoneHTTPResponse {
        PhoneHTTPResponse(status: status)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 426: "Upgrade Required"
        case 429: "Too Many Requests"
        case 501: "Not Implemented"
        default: status >= 500 ? "Internal Server Error" : "OK"
        }
    }
}

enum PhoneHTTPParser {
    enum Result {
        case needMore
        case request(PhoneHTTPRequest, consumed: Int)
        /// The status to answer with before closing.
        case invalid(Int)
    }

    static let maxHead = 16 * 1024
    static let maxBody = 1024 * 1024

    static func parse(_ buffer: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHead ? .invalid(413) : .needMore
        }
        guard end.lowerBound <= maxHead else { return .invalid(413) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(501) }

        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .invalid(400) }
            guard value <= maxBody else { return .invalid(413) }
            length = value
        }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .needMore }
        let body = Data(buffer[bodyStart..<bodyStart + length])

        let target = String(requestLine[1])
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(rawPath[0]).removingPercentEncoding, path.hasPrefix("/") else { return .invalid(400) }
        let query = rawPath.count > 1 ? PhoneHTTPForm.decode(String(rawPath[1])) : [:]

        let request = PhoneHTTPRequest(method: requestLine[0].uppercased(), path: path, query: query, headers: headers, body: body)
        return .request(request, consumed: bodyStart - buffer.startIndex + length)
    }
}

/// `application/x-www-form-urlencoded`, as the OAuth token endpoint and query strings use.
enum PhoneHTTPForm {
    static func decode(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = unescape(String(parts[0])), !name.isEmpty else { continue }
            result[name] = parts.count > 1 ? (unescape(String(parts[1])) ?? "") : ""
        }
        return result
    }

    private static func unescape(_ text: String) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
