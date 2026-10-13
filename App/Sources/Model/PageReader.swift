import Foundation
import WebKit

/// Loads a web page the way a browser would, offscreen, and hands back its rendered HTML.
/// Needed for sites that refuse plain fetches or fill their pages by script (Facebook does both), so a pasted link
/// can be read for its video without the browser extension.
@MainActor
final class PageReader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    /// Facebook tailors its page to the browser: Safari gets progressive H.264 files, Chrome gets the DASH table
    /// (often VP9 or AV1 only). The reader loads as either.
    enum Browser {
        case safari, chrome
        var userAgent: String {
            switch self {
            case .safari: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            case .chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
            }
        }
    }

    init(as browser: Browser) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.customUserAgent = browser.userAgent
        super.init()
        webView.navigationDelegate = self
    }

    /// The page's HTML once it has loaded and had `settle` seconds to fill itself in.
    func html(of url: URL, settle: TimeInterval = 4, timeout: TimeInterval = 25) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try await Task.sleep(for: .seconds(timeout))
                self?.finishLoad(.failure(PageReadError.timedOut))
            }
            self.webView.load(URLRequest(url: url))
        }
        try await Task.sleep(for: .seconds(settle))
        let result = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        guard let html = result as? String else { throw PageReadError.noHTML }
        return html
    }

    private var timeoutTask: Task<Void, Error>?

    private func finishLoad(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    enum PageReadError: Error, LocalizedError {
        case timedOut, noHTML
        var errorDescription: String? {
            switch self {
            case .timedOut: "The page took too long to load."
            case .noHTML: "The page could not be read."
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }
}
