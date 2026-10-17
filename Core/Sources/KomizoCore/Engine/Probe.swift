import Foundation

public struct ProbeResult: Sendable, Hashable {
    public var finalURL: URL
    public var size: Int64?
    public var acceptsRanges: Bool
    public var validator: String?
    public var suggestedName: String
    public var contentType: String?

    public init(finalURL: URL, size: Int64?, acceptsRanges: Bool, validator: String?, suggestedName: String, contentType: String?) {
        self.finalURL = finalURL
        self.size = size
        self.acceptsRanges = acceptsRanges
        self.validator = validator
        self.suggestedName = suggestedName
        self.contentType = contentType
    }
}

public enum ProbeError: Error, Equatable {
    case notHTTP
    case status(Int)
}

/// Learns what a URL serves before any byte of it is downloaded: a `GET` with `Range: bytes=0-0`, cancelled as soon
/// as the headers arrive. A `206` means the server honours ranges; a `200` means it does not.
public enum Probe {
    public static func run(_ url: URL, context: RequestContext, session: URLSession) async throws -> ProbeResult {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in context.allHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let response = try await HeadersOnly.fetch(request, session: session, original: url)
        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw ProbeError.status(http.statusCode) }
        let finalURL = http.url ?? url

        var size: Int64?
        var acceptsRanges = false
        if http.statusCode == 206, let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = contentRange.lastIndex(of: "/"), let total = Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            size = total
            acceptsRanges = true
        } else if let length = http.value(forHTTPHeaderField: "Content-Length"), let total = Int64(length) {
            size = total
        }

        let validator = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
        let disposition = http.value(forHTTPHeaderField: "Content-Disposition").flatMap(Filename.fromContentDisposition)
        let name = Filename.sanitised(disposition ?? Filename.fromURL(finalURL))
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return ProbeResult(finalURL: finalURL, size: size, acceptsRanges: acceptsRanges, validator: validator, suggestedName: name, contentType: contentType)
    }
}

/// Runs a data task only until its response headers arrive, then cancels it. Cancelling the Swift task cancels it too.
final class HeadersOnly: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private let original: URL

    private init(original: URL) { self.original = original }

    static func fetch(_ request: URLRequest, session: URLSession, original: URL) async throws -> URLResponse {
        let delegate = HeadersOnly(original: original)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = delegate
                delegate.lock.withLock { delegate.task = task }
                task.resume()
            }
        } onCancel: {
            delegate.lock.withLock { delegate.task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Redirects.scrub(request, original: original))
    }

    private func finish(_ result: Result<URLResponse, Error>) {
        let continuation: CheckedContinuation<URLResponse, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        finish(.success(response))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Reached only when the task failed before any response; a cancelled task after headers already finished.
        finish(.failure(error ?? URLError(.unknown)))
    }
}


enum Redirects {
    /// A redirect to another host must not carry the site's cookies along, as a browser would not.
    static func scrub(_ request: URLRequest, original: URL) -> URLRequest {
        guard let url = request.url, RequestContext.host(url) != RequestContext.host(original) else { return request }
        var scrubbed = request
        scrubbed.setValue(nil, forHTTPHeaderField: "Cookie")
        return scrubbed
    }
}
