import Foundation
import Network
import os

/// What an extension sends for a download it caught.
public struct IncomingDownload: Codable, Sendable, Hashable {
    public var url: String
    public var filename: String?
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    public var headers: [String: String]?
    /// `file`, `hls`, `mpd`, `dash` or `page`; only on `/media`.
    public var kind: String?
    public var pageTitle: String?
    /// For `dash`: the audio track; `url` is the video track.
    public var audioUrl: String?
    /// The site's id for the video, for naming when the page title names nothing.
    public var videoId: String?

    public init(url: String, filename: String? = nil, referrer: String? = nil, cookies: String? = nil, userAgent: String? = nil,
                headers: [String: String]? = nil, kind: String? = nil, pageTitle: String? = nil, audioUrl: String? = nil, videoId: String? = nil) {
        self.url = url
        self.filename = filename
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.headers = headers
        self.kind = kind
        self.pageTitle = pageTitle
        self.audioUrl = audioUrl
        self.videoId = videoId
    }

    public var context: RequestContext {
        RequestContext(referrer: referrer, cookies: cookies, userAgent: userAgent, headers: headers ?? [:])
    }
}

public struct PairRequest: Codable, Sendable, Hashable {
    public var client: String
    public var name: String

    public init(client: String, name: String) {
        self.client = client
        self.name = name
    }
}

public struct ServerStatus: Codable, Sendable, Hashable {
    public struct Features: Codable, Sendable, Hashable {
        public var media: Bool
        public init(media: Bool) { self.media = media }
    }

    public var app = "downhaul"
    public var version: String
    /// What this build offers; the grabber is always on, the field stays so the extension's check keeps working.
    public var features: Features
    /// Filled in per reply: whether any browser has paired.
    public var paired = false

    public init(version: String, features: Features = Features(media: true)) {
        self.version = version
        self.features = features
    }
}

public enum ServerError: Error {
    case badRequest(String)
    case listenFailed(String)
}

/// The extension asks what a page's media items are (length, tracks) so it can tell which is the video being watched.
public struct InspectRequest: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var url: String
        /// `file`, `hls` or `mpd`.
        public var kind: String
        public var cookies: String?

        public init(url: String, kind: String, cookies: String? = nil) {
            self.url = url
            self.kind = kind
            self.cookies = cookies
        }
    }

    public var items: [Item]
    public var referrer: String?
    public var userAgent: String?

    public init(items: [Item], referrer: String? = nil, userAgent: String? = nil) {
        self.items = items
        self.referrer = referrer
        self.userAgent = userAgent
    }
}

public protocol ExtensionServerDelegate: AnyObject, Sendable {
    /// Ask the user whether this browser may send downloads. Waits for the answer.
    func server(_ server: ExtensionServer, approvePairing request: PairRequest) async -> Bool
    /// A download (or, with `media`, a media item) to add; returns its id.
    func server(_ server: ExtensionServer, receive download: IncomingDownload, media: Bool) async throws -> UUID
    /// What each item is, as far as its first bytes or its playlist tell.
    func server(_ server: ExtensionServer, inspect request: InspectRequest) async -> [InspectedMedia]
}

public extension ExtensionServerDelegate {
    func server(_ server: ExtensionServer, inspect request: InspectRequest) async -> [InspectedMedia] { [] }
}

/// The local HTTP server the browser extensions talk to, on the loopback interface only.
///
/// Every write needs an `Origin` with an extension scheme, which a web page cannot forge; `/downloads` and
/// `/media` also need the bearer token the app issued at pairing. `/status` is open so the extension can show
/// whether the app is running.
public final class ExtensionServer: @unchecked Sendable {
    public let requestedPort: UInt16
    private let lock = NSLock()
    private var _token: String
    private var _status: ServerStatus
    private var _paired = false
    private weak var delegate: ExtensionServerDelegate?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.zewify.downhaul.server")
    private let log = Logger(subsystem: "com.zewify.downhaul", category: "server")
    private var _port: UInt16 = 0
    private var _lastError: String?
    private var _isListening = false

    static let extensionSchemes = ["chrome-extension://", "safari-web-extension://", "moz-extension://"]
    /// How long `/pair` waits for the user.
    public static let pairingTimeout: Duration = .seconds(60)
    /// An inspection answers within this, with what it has; the popup is waiting on it.
    public static let inspectTimeout: Duration = .seconds(6)
    public static let inspectLimit = 16

    public init(port: UInt16, token: String, status: ServerStatus, delegate: ExtensionServerDelegate) {
        requestedPort = port
        _token = token
        _status = status
        self.delegate = delegate
    }

    public var token: String {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    public var paired: Bool {
        get { lock.withLock { _paired } }
        set { lock.withLock { _paired = newValue } }
    }

    /// The port actually bound; equals the requested one unless that was 0.
    public var port: UInt16 { lock.withLock { _port } }
    public var isListening: Bool { lock.withLock { _isListening } }
    public var lastError: String? { lock.withLock { _lastError } }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock { self._port = listener.port?.rawValue ?? 0; self._isListening = true; self._lastError = nil }
                ready.signal()
            case .failed(let error):
                self.lock.withLock { self._isListening = false; self._lastError = error.localizedDescription }
                self.log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                ready.signal()
            case .cancelled:
                self.lock.withLock { self._isListening = false }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let message = lastError { throw ServerError.listenFailed(message) }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.withLock { _isListening = false }
    }

    // MARK: Connections

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 1 << 20 {
                self.reply(connection, .error(400, "Request too large"))
                return
            }
            if let (request, _) = HTTPRequest.parse(buffer) {
                Task { self.reply(connection, await self.handle(request)) }
            } else if error == nil, !isComplete {
                self.receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func reply(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialised(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Routes

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let origin = request.headers["origin"]
        let fromExtension = origin.map { o in Self.extensionSchemes.contains { o.hasPrefix($0) } } ?? false
        let allowOrigin = fromExtension ? origin : nil

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, headers: [
                ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
                ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
                ("Access-Control-Max-Age", "600"),
            ], origin: allowOrigin ?? "null")
        }

        switch (request.method, request.path) {
        case ("GET", "/status"):
            var status = lock.withLock { _status }
            status.paired = paired
            return HTTPResponse(status: 200, json: status, origin: allowOrigin)

        case ("POST", "/pair"):
            guard fromExtension else { return .error(403, "Only a browser extension may pair", origin: allowOrigin) }
            guard let pair = try? JSONDecoder().decode(PairRequest.self, from: request.body) else {
                return .error(400, "Bad pairing request", origin: allowOrigin)
            }
            guard let delegate else { return .error(500, "No delegate", origin: allowOrigin) }
            let approved = await withTimeout(Self.pairingTimeout) { await delegate.server(self, approvePairing: pair) } ?? false
            guard approved else { return .error(403, "The user did not allow this browser", origin: allowOrigin) }
            paired = true
            struct Reply: Encodable { let token: String }
            return HTTPResponse(status: 200, json: Reply(token: token), origin: allowOrigin)

        case ("POST", "/downloads"), ("POST", "/media"):
            let media = request.path == "/media"
            if media, !lock.withLock({ _status.features.media }) { return .error(404, "Not available in this edition", origin: allowOrigin) }
            guard fromExtension else { return .error(403, "Only a browser extension may send downloads", origin: allowOrigin) }
            guard request.headers["authorization"] == "Bearer \(token)" else { return .error(401, "Not paired", origin: allowOrigin) }
            guard let incoming = try? JSONDecoder().decode(IncomingDownload.self, from: request.body) else {
                return .error(400, "Bad download request", origin: allowOrigin)
            }
            guard let url = URL(string: incoming.url), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
                return .error(400, "Only http and https links can be downloaded", origin: allowOrigin)
            }
            guard let delegate else { return .error(500, "No delegate", origin: allowOrigin) }
            do {
                let id = try await delegate.server(self, receive: incoming, media: media)
                struct Reply: Encodable { let id: String }
                return HTTPResponse(status: 201, json: Reply(id: id.uuidString), origin: allowOrigin)
            } catch ServerError.badRequest(let message) {
                return .error(400, message, origin: allowOrigin)
            } catch {
                return .error(500, error.localizedDescription, origin: allowOrigin)
            }

        case ("POST", "/inspect"):
            if !lock.withLock({ _status.features.media }) { return .error(404, "Not available in this edition", origin: allowOrigin) }
            guard fromExtension else { return .error(403, "Only a browser extension may ask", origin: allowOrigin) }
            guard request.headers["authorization"] == "Bearer \(token)" else { return .error(401, "Not paired", origin: allowOrigin) }
            guard var inspect = try? JSONDecoder().decode(InspectRequest.self, from: request.body) else {
                return .error(400, "Bad inspect request", origin: allowOrigin)
            }
            // Only web addresses, and few enough that the popup never waits long.
            inspect.items = Array(inspect.items.filter { item in
                URL(string: item.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } ?? false
            }.prefix(Self.inspectLimit))
            guard let delegate else { return .error(500, "No delegate", origin: allowOrigin) }
            let asked = inspect
            let found = await withTimeout(Self.inspectTimeout) { await delegate.server(self, inspect: asked) } ?? []
            return HTTPResponse(status: 200, json: found, origin: allowOrigin)

        default:
            return .error(404, "No such route", origin: allowOrigin)
        }
    }
}

/// Runs `operation`, giving up with nil after `timeout`.
func withTimeout<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask { try? await Task.sleep(for: timeout); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
