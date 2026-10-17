import AppKit
import KomizoCore
import Observation
import os
import ServiceManagement

/// A download the extension sent that waits for the user in the catch panel.
struct PendingCatch: Identifiable, Sendable {
    let id = UUID()
    var incoming: IncomingDownload
    var media: Bool
    var name: String
    var folder: URL
    var probe: ProbeResult?
    var error: String?
    /// The error is about the stream itself (protected, live, nothing a Mac plays), not about reaching it.
    var streamError = false
    var context: RequestContext { incoming.context }
    var kind: DownloadKind {
        switch incoming.kind {
        case "hls": .hls
        case "mpd": .mpd
        case "dash": .dash
        default: .file
        }
    }
}

/// The app's state: the library and its settings, the engine, the local server, licences and what waits for the user.
@MainActor
@Observable
final class AppModel {
    private(set) var library: Library
    let engine: DownloadEngine
    private(set) var serverError: String?
    private(set) var serverListening = false
    /// Downloads the extension sent, oldest first; the catch panel shows the first.
    private(set) var pending: [PendingCatch] = []
    /// Called when a catch arrives, so the window manager can show the panel.
    @ObservationIgnored var onPending: (() -> Void)?
    /// How a pairing request is put to the user; tests replace the alert.
    @ObservationIgnored var pairingApprover: @MainActor (PairRequest) async -> Bool

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var server: ExtensionServer?
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var scopedFolder: URL?
    @ObservationIgnored private let session = URLSession(configuration: DownloadEngine.sessionConfiguration())
    @ObservationIgnored private let log = Logger(subsystem: "com.zewify.komizo", category: "model")

    var settings: Settings { library.settings }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    init(store: LibraryStore = .standard) {
        self.store = store
        var library = store.load()
        library.settings.connections = Limits.clampConnections(library.settings.connections)
        library.settings.concurrent = Limits.clampConcurrent(library.settings.concurrent)
        self.library = library
        let folder = Self.resolveFolder(library.settings)
        scopedFolder = folder.scoped
        engine = DownloadEngine(downloads: library.downloads, connections: library.settings.connections,
                                concurrent: library.settings.concurrent, folder: folder.url)
        engine.speedLimit = library.settings.effectiveSpeedLimit
        pairingApprover = { request in
            await AppModel.askToPair(request)
        }
        engine.onChange = { [weak self] in self?.markDirty() }
    }

    /// Starts the server and the periodic save. Not called by hosted tests.
    func start() {
        startServer()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveIfNeeded(includingProgress: true) }
        }
    }

    // MARK: Saving

    private func markDirty() { dirty = true }

    /// Writes the library when something changed; with `includingProgress`, also while anything is running,
    /// so a crash loses at most a second of segment state.
    func saveIfNeeded(includingProgress: Bool) {
        let running = engine.downloads.contains { $0.state.isRunning }
        guard dirty || (includingProgress && running) else { return }
        flush()
    }

    func flush() {
        library.downloads = engine.downloads
        do {
            try store.save(library)
            dirty = false
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Settings

    func setAskBeforeStarting(_ value: Bool) { library.settings.askBeforeStarting = value; markDirty() }

    func setConnections(_ value: Int) {
        library.settings.connections = Limits.clampConnections(value)
        engine.connections = library.settings.connections
        markDirty()
    }

    /// Turns the cap on or off; running downloads follow at once.
    func setLimitSpeed(_ value: Bool) {
        library.settings.limitSpeed = value
        engine.speedLimit = library.settings.effectiveSpeedLimit
        markDirty()
    }

    func setSpeedLimit(_ bytesPerSecond: Int64) {
        library.settings.speedLimit = max(bytesPerSecond, SpeedLimiter.minimum)
        engine.speedLimit = library.settings.effectiveSpeedLimit
        markDirty()
    }

    func setConcurrent(_ value: Int) {
        library.settings.concurrent = Limits.clampConcurrent(value)
        engine.concurrent = library.settings.concurrent
        markDirty()
    }

    func setPort(_ value: UInt16) {
        guard value != library.settings.port else { return }
        library.settings.port = value
        markDirty()
        startServer()
    }

    /// Keeps a security-scoped bookmark so the sandbox lets the app back into the folder after a relaunch.
    func setFolder(_ url: URL) {
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        if url.standardizedFileURL == Self.defaultFolder.standardizedFileURL {
            library.settings.downloadFolderPath = nil
            library.settings.downloadFolderBookmark = nil
        } else {
            library.settings.downloadFolderPath = url.path
            library.settings.downloadFolderBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let folder = Self.resolveFolder(library.settings)
        scopedFolder = folder.scoped
        engine.folder = folder.url
        markDirty()
    }

    var folder: URL { engine.folder }
    static var defaultFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    private static func resolveFolder(_ settings: Settings) -> (url: URL, scoped: URL?) {
        if let data = settings.downloadFolderBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                return (url, url)
            }
        }
        if let path = settings.downloadFolderPath { return (URL(fileURLWithPath: path), nil) }
        return (defaultFolder, nil)
    }

    func setOpenAtLogin(_ value: Bool) {
        library.settings.openAtLogin = value
        markDirty()
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    func forgetPairedClients() {
        library.settings.pairedClients = []
        library.settings.pairingToken = Settings.makeToken()
        server?.token = library.settings.pairingToken
        server?.paired = false
        markDirty()
    }

    // MARK: Adding downloads

    enum AddError: Error, LocalizedError {
        case notAURL(String)
        case probe(String, String)
        case webPage(String)
        case noVideoOnPage(String)

        var errorDescription: String? {
            switch self {
            case .notAURL(let text): "“\(text)” is not an http or https link."
            case .probe(let url, let message): "\(url): \(message)"
            case .webPage(let url): "\(url) is a web page, not a file. Open it in your browser and use the Komizo extension to grab what is on it."
            case .noVideoOnPage(let url): "No video found on \(url). It may need a login, or the post may be private; open it in your browser and use the Komizo extension."
            }
        }
    }

    /// Adds every http(s) link in the text, one per line, probing each for its name. Throws for the first that fails.
    func addURLs(_ text: String) async throws {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines {
            guard let url = URL(string: line), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
                throw AddError.notAURL(line)
            }
            let probe: ProbeResult
            do {
                probe = try await Probe.run(url, context: RequestContext(), session: session)
            } catch {
                throw AddError.probe(line, Self.describe(error))
            }
            if probe.contentType == "text/html" {
                // A page, not a file: a Facebook video page can still be read for its tracks; anything else needs the extension.
                guard FacebookPage.isFacebook(url) else { throw AddError.webPage(line) }
                guard let download = try await facebookDownload(for: url) else { throw AddError.noVideoOnPage(line) }
                engine.add(download)
                continue
            }
            var download = Download(url: url, name: probe.suggestedName, folder: folder)
            download.finalURL = probe.finalURL
            download.size = probe.size
            download.contentType = probe.contentType
            engine.add(download)
        }
    }

    /// Loads a Facebook video page offscreen as a browser would (a plain fetch is refused, and the page fills itself
    /// by script): first as Safari, which gets progressive H.264 files, then as Chrome, which gets the DASH table.
    func facebookDownload(for url: URL) async throws -> Download? {
        let safariHTML = try await PageReader(as: .safari).html(of: url)
        if let download = FacebookPage.download(for: url, html: safariHTML, folder: folder) { return download }
        let chromeHTML = try await PageReader(as: .chrome).html(of: url)
        return FacebookPage.download(for: url, html: chromeHTML, folder: folder)
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? DownloadFailure { return failure.message }
        if let probe = error as? ProbeError {
            switch probe {
            case .status(let code): return "the server answered \(code)"
            case .notHTTP: return "not an HTTP response"
            }
        }
        return error.localizedDescription
    }

    // MARK: Catches from the extension

    func startCatch(_ pending: PendingCatch) {
        self.pending.removeAll { $0.id == pending.id }
        var download = Download(url: URL(string: pending.incoming.url)!, kind: pending.kind, name: pending.name, folder: pending.folder, context: pending.context)
        download.media = pending.media
        download.audioURL = pending.incoming.audioUrl.flatMap(URL.init(string:))
        if pending.folder.standardizedFileURL != folder.standardizedFileURL {
            // A folder chosen for this download alone: the sandbox only lets the app back in through a bookmark.
            download.folderBookmark = try? pending.folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        if let probe = pending.probe {
            download.finalURL = probe.finalURL
            download.size = probe.size
            download.contentType = probe.contentType
        }
        engine.add(download)
    }

    func dismissCatch(_ pending: PendingCatch) {
        self.pending.removeAll { $0.id == pending.id }
    }

    #if DEBUG
    func appendPendingForDebugging(_ pending: PendingCatch) { self.pending.append(pending) }
    #endif

    /// Builds the catch for an incoming download: for a file, a probe for its real name and size; for a stream, the page title.
    private func makeCatch(_ incoming: IncomingDownload, media: Bool) async -> PendingCatch {
        var pending = PendingCatch(incoming: incoming, media: media, name: "", folder: folder)
        let kind = pending.kind
        guard let url = URL(string: incoming.url) else {
            pending.error = "Not a URL"
            return pending
        }
        if kind.isStream {
            pending.name = Filename.mediaName(pageTitle: incoming.pageTitle ?? "Stream", url: url, contentType: nil)
            // Read the playlist or manifest now, so a protected or live stream says so before anything is queued.
            do {
                let plan = try await StreamSource.plan(kind, url: url, fetcher: MediaFetcher(context: incoming.context, session: session, retryDelays: [1]))
                // A DASH site that serves each track as one whole file gets the segmented file engine instead.
                if kind == .mpd, let video = plan.video.wholeFile {
                    var whole = incoming
                    whole.url = video.absoluteString
                    whole.audioUrl = plan.audio?.wholeFile?.absoluteString
                    whole.kind = whole.audioUrl == nil ? "file" : "dash"
                    if plan.audio == nil || whole.audioUrl != nil { return await makeCatch(whole, media: media) }
                }
            } catch {
                pending.error = Self.describe(error)
                pending.streamError = true
            }
            return pending
        }
        if incoming.kind == "page" {
            // The extension hands over the page itself; Komizo reads it as Safari would and takes the H.264 file.
            guard FacebookPage.isFacebook(url) else { pending.error = "Komizo can only read Facebook video pages"; return pending }
            do {
                guard let download = try await facebookDownload(for: url) else {
                    pending.error = "No video found on that page (it may need a login)"
                    return pending
                }
                pending.incoming = IncomingDownload(url: download.url.absoluteString, referrer: incoming.referrer, cookies: incoming.cookies, userAgent: incoming.userAgent,
                                                    kind: "dash", pageTitle: incoming.pageTitle, audioUrl: download.audioURL?.absoluteString, videoId: incoming.videoId)
                pending.name = download.name
            } catch {
                pending.error = Self.describe(error)
            }
            return pending
        }
        if kind == .dash {
            guard let audio = incoming.audioUrl, let audioURL = URL(string: audio), ["http", "https"].contains(audioURL.scheme?.lowercased() ?? "") else {
                pending.error = "The stream names no audio track"
                return pending
            }
            pending.name = Filename.mediaName(pageTitle: incoming.pageTitle ?? "Video", url: url, contentType: "video/mp4", videoId: incoming.videoId)
            if let probe = try? await Probe.run(url, context: incoming.context, session: session) { pending.probe = probe }
            return pending
        }
        do {
            let probe = try await Probe.run(url, context: incoming.context, session: session)
            pending.probe = probe
            let headerNamedIt = probe.suggestedName != Filename.sanitised(Filename.fromURL(probe.finalURL))
            if let filename = incoming.filename {
                pending.name = Filename.sanitised(filename)
            } else if media, !headerNamedIt {
                pending.name = Filename.mediaName(pageTitle: incoming.pageTitle, url: probe.finalURL, contentType: probe.contentType, videoId: incoming.videoId)
            } else {
                pending.name = probe.suggestedName
            }
            // Grabbed media that a server names without an extension ("it asks") would not open by double-click.
            if media, (pending.name as NSString).pathExtension.isEmpty, let ext = Filename.fileExtension(for: probe.contentType) {
                pending.name += "." + ext
            }
        } catch {
            pending.error = Self.describe(error)
            pending.name = incoming.filename.map(Filename.sanitised) ?? Filename.sanitised(Filename.fromURL(url))
        }
        return pending
    }

    // MARK: The server

    func startServer() {
        server?.stop()
        let status = ServerStatus(version: Self.version)
        let server = ExtensionServer(port: settings.port, token: settings.pairingToken, status: status, delegate: self)
        server.paired = !settings.pairedClients.isEmpty
        self.server = server
        do {
            try server.start()
            serverListening = true
            serverError = nil
        } catch {
            serverListening = false
            serverError = "Port \(settings.port) could not be opened: \(error.localizedDescription). Komizo tries again every ten seconds."
            log.error("server: \(error.localizedDescription, privacy: .public)")
            Task { try? await Task.sleep(for: .seconds(10)); if !self.serverListening { self.startServer() } }
        }
    }

    var serverPort: UInt16 { settings.port }

    static func askToPair(_ request: PairRequest) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow \(request.name) to send downloads to Komizo?"
        alert.informativeText = "The Komizo extension in \(request.name) wants to hand its downloads to this app. Only allow browsers you use yourself."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension AppModel: ExtensionServerDelegate {
    func server(_ server: ExtensionServer, approvePairing request: PairRequest) async -> Bool {
        let approved = await pairingApprover(request)
        if approved {
            library.settings.pairedClients.removeAll { $0.client == request.client && $0.name == request.name }
            library.settings.pairedClients.append(PairedClient(client: request.client, name: request.name))
            markDirty()
        }
        return approved
    }

    func server(_ server: ExtensionServer, receive download: IncomingDownload, media: Bool) async throws -> UUID {
        let pending = await makeCatch(download, media: media)
        if let error = pending.error {
            // Refused, so the browser keeps its own download rather than ending up with neither.
            throw ServerError.badRequest(pending.streamError ? error : "Komizo could not reach the file: \(error)")
        }
        if settings.askBeforeStarting {
            self.pending.append(pending)
            onPending?()
            return pending.id
        }
        startCatch(pending)
        return engine.downloads.last?.id ?? pending.id
    }

    /// Reads each item's head or playlist, all at once and without retries: the popup is waiting on the answer.
    func server(_ server: ExtensionServer, inspect request: InspectRequest) async -> [InspectedMedia] {
        let session = self.session
        return await withTaskGroup(of: InspectedMedia?.self) { group in
            for item in request.items {
                guard let url = URL(string: item.url) else { continue }
                let context = RequestContext(referrer: request.referrer, cookies: item.cookies, userAgent: request.userAgent)
                group.addTask { await MediaInspector.inspect(url, kind: item.kind, fetcher: MediaFetcher(context: context, session: session, retryDelays: [])) }
            }
            var found: [InspectedMedia] = []
            for await result in group { if let result { found.append(result) } }
            return found
        }
    }
}
