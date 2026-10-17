import Foundation

/// A data task as an async stream of its response and body chunks, cancelled when the consumer stops reading.
/// Chunks arrive as the session delivers them (tens of KiB), which is far cheaper than `URLSession.AsyncBytes`.
///
/// Flow control: at most about a mebibyte waits unread. Past that the task is suspended, so the socket stops being read
/// and TCP slows the sender, until the reader has used enough of it (each chunk's `consumed`). A slow disk or a speed
/// limit therefore slows the network itself instead of piling the body up in memory.
final class HTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        /// A chunk; call `consumed` once it is used, so the stream reads on.
        case data(Data, consumed: @Sendable () -> Void)
    }

    static let highWater = 1 << 20
    static let lowWater = 256 << 10

    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let original: URL
    private let lock = NSLock()
    private var unread = 0
    private var suspended: URLSessionTask?

    private init(_ continuation: AsyncThrowingStream<Event, Error>.Continuation, original: URL) {
        self.continuation = continuation
        self.original = original
    }

    /// `original` is the URL the user gave: cookies are dropped on a redirect away from its host.
    static func open(_ request: URLRequest, session: URLSession, original: URL) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let delegate = HTTPStream(continuation, original: original)
            let task = session.dataTask(with: request)
            task.delegate = delegate
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        continuation.yield(.response(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Redirects.scrub(request, original: original))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let count = data.count
        let suspend = lock.withLock {
            unread += count
            guard unread > Self.highWater, suspended == nil else { return false }
            suspended = dataTask
            return true
        }
        if suspend { dataTask.suspend() }
        continuation.yield(.data(data, consumed: { [weak self] in self?.consumed(count) }))
    }

    private func consumed(_ count: Int) {
        let resume = lock.withLock { () -> URLSessionTask? in
            unread -= count
            guard unread < Self.lowWater, let task = suspended else { return nil }
            suspended = nil
            return task
        }
        // Resuming a task cancelled meanwhile does nothing.
        resume?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error)
    }
}
