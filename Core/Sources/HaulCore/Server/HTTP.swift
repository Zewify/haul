import Foundation

/// Just enough HTTP/1.1 for small JSON requests from a browser extension on the same machine.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// The path without its query string.
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    /// A complete request at the start of `buffer`, with how many bytes it took; nil until the whole body is there.
    public static func parse(_ buffer: Data) -> (HTTPRequest, Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let request = HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body)
        return (request, bodyStart - buffer.startIndex + length)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data(), origin: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        if let origin { self.headers.append(("Access-Control-Allow-Origin", origin)) }
    }

    public init(status: Int, json: some Encodable, origin: String? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        self.init(status: status, headers: [("Content-Type", "application/json")], body: (try? encoder.encode(json)) ?? Data(), origin: origin)
    }

    public static func error(_ status: Int, _ message: String, origin: String? = nil) -> HTTPResponse {
        struct Body: Encodable { let error: String }
        return HTTPResponse(status: status, json: Body(error: message), origin: origin)
    }

    public func serialised() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
