import AppKit
import HaulCore
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
    var context: RequestContext { incoming.context }
    var kind: DownloadKind { incoming.kind == "hls" ? .hls : .file }
}

/// The app's state: the library and its settings, the engine, the local server, licences and what waits for the user.
@MainActor
@Observable
final class AppModel {
    private(set) var library: Library
    let engine: DownloadEngine
    private(set) var license: License?
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
    @ObservationIgnored private let log = Logger(subsystem: "com.zewify.haul", category: "model")

    var settings: Settings { library.settings }
    var edition: Edition { Edition.current }
    var isPro: Bool { license != nil }
    var gate: FeatureGate { FeatureGate(edition: edition, isPro: isPro) }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    init(store: LibraryStore = .standard) {
        self.store = store
        var library = store.load()
        var license: License?
        #if DEBUG
        // `-HaulForcePro YES` unlocks Pro for UI checks without a licence.
        if UserDefaults.standard.bool(forKey: "HaulForcePro") {
            license = License(id: "debug", licensee: "Debug build")
        }
        #endif
        if license == nil, let key = library.settings.licenseKey { license = try? License.verify(key) }
        self.license = license
        let gate = FeatureGate(edition: Edition.current, isPro: license != nil)
        library.settings.connections = gate.clampConnections(library.settings.connections)
        library.settings.concurrent = gate.clampConcurrent(library.settings.concurrent)
        self.library = library
        let folder = Self.resolveFolder(library.settings)
        scopedFolder = folder.scoped
        engine = DownloadEngine(downloads: library.downloads, gate: gate, connections: library.settings.connections,
                                concurrent: library.settings.concurrent, folder: folder.url)
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
        library.settings.connections = gate.clampConnections(value)
        engine.connections = library.settings.connections
        markDirty()
    }

    func setConcurrent(_ value: Int) {
        library.settings.concurrent = gate.clampConcurrent(value)
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

    enum LicenseProblem: Error, LocalizedError {
        case malformed, badSignature, wrongProduct

        var errorDescription: String? {
            switch self {
            case .malformed: "That does not look like a Haul licence key. Paste the whole key, including HAUL1-."
            case .badSignature: "This key was not issued by Zewify."
            case .wrongProduct: "This key is for another Zewify product."
            }
        }
    }

    func setLicense(_ key: String) throws {
        do {
            license = try License.verify(key)
        } catch .malformed { throw LicenseProblem.malformed }
        catch .badSignature { throw LicenseProblem.badSignature }
        catch .wrongProduct { throw LicenseProblem.wrongProduct }
        library.settings.licenseKey = key.filter { !$0.isWhitespace }
        engine.gate = gate
        restartServer()
        markDirty()
    }

    func removeLicense() {
        license = nil
        library.settings.licenseKey = nil
        setConnections(library.settings.connections)
        setConcurrent(library.settings.concurrent)
        engine.gate = gate
        restartServer()
    }

    // MARK: Adding downloads

    enum AddError: Error, LocalizedError {
        case notAURL(String)
        case probe(String, String)

        var errorDescription: String? {
            switch self {
            case .notAURL(let text): "“\(text)” is not an http or https link."
            case .probe(let url, let message): "\(url): \(message)"
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
            var download = Download(url: url, name: probe.suggestedName, folder: folder)
            download.finalURL = probe.finalURL
            download.size = probe.size
            download.contentType = probe.contentType
            engine.add(download)
        }
    }

    static func describe(_ error: Error) -> String {
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
        let kind: DownloadKind = incoming.kind == "hls" ? .hls : .file
        var pending = PendingCatch(incoming: incoming, media: media, name: "", folder: folder)
        if kind == .hls {
            let title = incoming.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pending.name = Filename.sanitised(title.isEmpty ? "Stream" : title)
            return pending
        }
        guard let url = URL(string: incoming.url) else {
            pending.error = "Not a URL"
            return pending
        }
        do {
            let probe = try await Probe.run(url, context: incoming.context, session: session)
            pending.probe = probe
            pending.name = incoming.filename.map(Filename.sanitised) ?? probe.suggestedName
        } catch {
            pending.error = Self.describe(error)
            pending.name = incoming.filename.map(Filename.sanitised) ?? Filename.sanitised(Filename.fromURL(url))
        }
        return pending
    }

    // MARK: The server

    func startServer() {
        server?.stop()
        let status = ServerStatus(version: Self.version, edition: edition, features: .init(media: gate.offersMedia))
        let server = ExtensionServer(port: settings.port, token: settings.pairingToken, status: status, delegate: self)
        server.paired = !settings.pairedClients.isEmpty
        self.server = server
        do {
            try server.start()
            serverListening = true
            serverError = nil
        } catch {
            serverListening = false
            serverError = "Port \(settings.port) could not be opened: \(error.localizedDescription). Haul tries again every ten seconds."
            log.error("server: \(error.localizedDescription, privacy: .public)")
            Task { try? await Task.sleep(for: .seconds(10)); if !self.serverListening { self.startServer() } }
        }
    }

    private func restartServer() {
        if server != nil { startServer() }
    }

    var serverPort: UInt16 { settings.port }

    static func askToPair(_ request: PairRequest) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow \(request.name) to send downloads to Haul?"
        alert.informativeText = "The Haul extension in \(request.name) wants to hand its downloads to this app. Only allow browsers you use yourself."
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
        if media, !gate.allows(.mediaGrabber) {
            throw ServerError.badRequest("Grabbing video needs Haul Pro.")
        }
        let pending = await makeCatch(download, media: media)
        if settings.askBeforeStarting || pending.error != nil {
            self.pending.append(pending)
            onPending?()
            return pending.id
        }
        startCatch(pending)
        return engine.downloads.last?.id ?? pending.id
    }
}
