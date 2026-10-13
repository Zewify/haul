import Foundation

/// A data task as an async stream of its response and body chunks, cancelled when the consumer stops reading.
/// Chunks arrive as the session delivers them (tens of KiB), which is far cheaper than `URLSession.AsyncBytes`.
final class HTTPStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let original: URL

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
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error)
    }
}
