import Foundation
import Network
import os

/// A small HTTP/1.1 server on an ephemeral `127.0.0.1` port for engine tests: serves resources with range support,
/// and can be told to refuse ranges, hide the length, drop connections mid-body, redirect, or delay.
/// Every request is recorded for assertions.
final class TestServer: @unchecked Sendable {
    struct Resource {
        var data: Data
        var contentType = "application/octet-stream"
        var headers: [String: String] = [:]
        var status = 200
    }

    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var _files: [String: Resource] = [:]
    private var _requests: [RecordedRequest] = []
    var supportsRanges = true
    var hidesLength = false
    var etag: String? = "\"v1\""
    /// Close the connection after this many body bytes, `dropTimes` times, then serve normally.
    var dropAfterBytes: Int?
    var dropTimes = 1
    private var dropsSoFar = 0
    /// Milliseconds to wait between 64 KiB chunks, to make downloads observable mid-flight.
    var chunkDelayMs: Int = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-server")
    private(set) var port: UInt16 = 0

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self {
                self.port = self.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        ready.wait()
    }

    deinit { listener.cancel() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

    subscript(path: String) -> Resource? {
        get { lock.withLock { _files[path] } }
        set { lock.withLock { _files[path] = newValue } }
    }

    var requests: [RecordedRequest] { lock.withLock { _requests } }
    func clearRequests() { lock.withLock { _requests.removeAll() } }
    /// The `Range` headers seen, in order.
    var rangesRequested: [String] { requests.compactMap { $0.headers["range"] } }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(to: request, on: connection)
            } else if error == nil, data != nil {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private static func parse(_ buffer: Data) -> RecordedRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return RecordedRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers)
    }

    private func respond(to request: RecordedRequest, on connection: NWConnection) {
        lock.withLock { _requests.append(request) }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard let resource = self[path] else {
            send(connection, status: 404, headers: [:], body: Data(), method: request.method)
            return
        }
        if resource.status / 100 == 3 {
            send(connection, status: resource.status, headers: resource.headers, body: Data(), method: request.method)
            return
        }
        var headers = resource.headers
        headers["Content-Type"] = resource.contentType
        if let etag { headers["ETag"] = etag }
        if supportsRanges { headers["Accept-Ranges"] = "bytes" }
        var body = resource.data
        var status = resource.status
        if supportsRanges, let range = request.headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let total = resource.data.count
            let start = Int(spec[0]) ?? 0
            let end = spec.count > 1 && !spec[1].isEmpty ? min(Int(spec[1]) ?? total - 1, total - 1) : total - 1
            if start > end || start >= total {
                send(connection, status: 416, headers: ["Content-Range": "bytes */\(total)"], body: Data(), method: request.method)
                return
            }
            body = resource.data.subdata(in: start..<(end + 1))
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }
        send(connection, status: status, headers: headers, body: body, method: request.method)
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data, method: String) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        let hidden = hidesLength && status / 100 == 2
        if hidden {
            head += "Connection: close\r\n"
        } else {
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n"
        }
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        if method == "HEAD" || body.isEmpty {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let shouldDrop: Bool = lock.withLock {
            guard dropAfterBytes != nil, dropsSoFar < dropTimes else { return false }
            dropsSoFar += 1
            return true
        }
        let limit = shouldDrop ? min(dropAfterBytes ?? body.count, body.count) : body.count
        sendChunks(connection, body: body, offset: 0, limit: limit, drop: shouldDrop)
    }

    private func sendChunks(_ connection: NWConnection, body: Data, offset: Int, limit: Int, drop: Bool) {
        if offset >= limit {
            if drop {
                connection.forceCancel()
            } else {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }
        let end = min(offset + 65536, limit)
        let chunk = body.subdata(in: offset..<end)
        let delay = chunkDelayMs
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard error == nil, let server = self else { connection.cancel(); return }
            let next: @Sendable () -> Void = { server.sendChunks(connection, body: body, offset: end, limit: limit, drop: drop) }
            if delay > 0 { server.queue.asyncAfter(deadline: .now() + .milliseconds(delay), execute: next) } else { next() }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 302: "Found"
        case 404: "Not Found"
        case 416: "Range Not Satisfiable"
        default: "Status"
        }
    }

    /// Random bytes, deterministic per seed so a test can compare.
    static func blob(_ size: Int, seed: UInt64 = 1) -> Data {
        var state = seed
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in 0..<size {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }
}
