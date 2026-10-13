import Foundation
import Observation
import os

/// Owns every download: the list the UI shows, the tasks running them, and the queue that decides which run.
/// Lives on the main actor so the UI reads it directly; the tasks themselves run off it.
@MainActor
@Observable
public final class DownloadEngine {
    public private(set) var downloads: [Download]
    /// Live progress of running downloads, by id.
    public private(set) var progress: [UUID: DownloadProgress] = [:]
    public var gate: FeatureGate { didSet { pump() } }
    /// User settings; the gate clamps them.
    public var connections: Int
    public var concurrent: Int { didSet { pump() } }
    public var folder: URL
    /// Called whenever the list or a record changes, so the owner can save the library.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private var tasks: [UUID: any Pausable] = [:]
    @ObservationIgnored private var runners: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let retryDelays: [TimeInterval]
    @ObservationIgnored private let log = Logger(subsystem: "com.zewify.haul", category: "engine")

    public init(downloads: [Download], gate: FeatureGate, connections: Int, concurrent: Int, folder: URL,
                retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays) {
        self.gate = gate
        self.connections = connections
        self.concurrent = concurrent
        self.folder = folder
        self.retryDelays = retryDelays
        session = URLSession(configuration: Self.sessionConfiguration())
        // Anything that was running when the app last quit waits for the user; queued ones carry on.
        self.downloads = downloads.map { download in
            var download = download
            if download.state.isRunning { download.state = .paused }
            return download
        }
        pump()
    }

    /// Many connections per host, and no cookie jar: the browser's cookies travel in each download's context.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 64
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        return config
    }

    public var effectiveConnections: Int { gate.clampConnections(connections) }
    public var effectiveConcurrent: Int { gate.clampConcurrent(concurrent) }

    public func download(_ id: UUID) -> Download? { downloads.first { $0.id == id } }
    public func progress(for id: UUID) -> DownloadProgress? { progress[id] }

    /// Speed and completion across everything running or queued; fraction is nil when nothing is active.
    public var combined: (bytesPerSecond: Double, fraction: Double?) {
        let active = downloads.filter { $0.state.isActive }
        let speed = active.reduce(0.0) { $0 + (progress[$1.id]?.bytesPerSecond ?? 0) }
        let sized = active.filter { $0.size != nil }
        guard !sized.isEmpty else { return (speed, nil) }
        let total = sized.reduce(Int64(0)) { $0 + $1.size! }
        let done = sized.reduce(Int64(0)) { $0 + $1.bytesReceived }
        return (speed, total > 0 ? Double(done) / Double(total) : nil)
    }

    // MARK: Adding and removing

    /// Adds a download to the end of the queue. Its name is made unique in its folder straight away, and its part
    /// file claimed, so two downloads of the same name never share one.
    @discardableResult
    public func add(_ request: Download) -> UUID {
        var download = request
        download.folder = request.folder
        download.name = Filename.available(Filename.sanitised(download.name), in: download.folder)
        download.state = .queued
        download.segments = []
        download.finalPath = nil
        let part = PartFile(folder: download.folder, name: download.name)
        try? part.prepare(size: nil)
        download.partPath = part.url.path
        downloads.append(download)
        changed()
        pump()
        return download.id
    }

    public func remove(_ id: UUID, deleteFile: Bool) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        let download = downloads[index]
        if let task = tasks[id] {
            Task { await task.cancel() }
        }
        if deleteFile, let path = download.finalPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let part = download.partPath {
            try? FileManager.default.removeItem(atPath: part)
        }
        downloads.remove(at: index)
        progress[id] = nil
        changed()
        pump()
    }

    // MARK: Control

    public func pause(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        if let task = tasks[id] {
            Task { await task.pause() }
        } else if downloads[index].state == .queued {
            downloads[index].state = .paused
            changed()
        }
    }

    public func resume(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), !downloads[index].state.isActive,
              downloads[index].state != .finished else { return }
        downloads[index].state = .queued
        changed()
        pump()
    }

    public func retry(_ id: UUID) { resume(id) }

    public func cancel(_ id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        if let task = tasks[id] {
            Task { await task.cancel() }
        } else if downloads[index].state != .finished {
            if let part = downloads[index].partPath { try? FileManager.default.removeItem(atPath: part) }
            downloads[index].segments = []
            downloads[index].state = .cancelled
            changed()
        }
    }

    public func pauseAll() {
        for download in downloads where download.state.isActive { pause(download.id) }
    }

    public func resumeAll() {
        for download in downloads where download.state == .paused { resume(download.id) }
    }

    // MARK: The queue

    /// Starts queued downloads, in order, while fewer than the limit are running.
    private func pump() {
        var running = downloads.filter { $0.state.isRunning }.count
        for download in downloads where download.state == .queued && running < effectiveConcurrent {
            start(download)
            running += 1
        }
    }

    private func start(_ download: Download) {
        guard let index = downloads.firstIndex(where: { $0.id == download.id }), tasks[download.id] == nil else { return }
        downloads[index].state = .probing
        let id = download.id
        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress, to: id) }
        }
        switch downloads[index].kind {
        case .file:
            let task = DownloadTask(download: downloads[index], connections: effectiveConnections, session: session,
                                    retryDelays: retryDelays, onProgress: onProgress)
            tasks[id] = task
            runners[id] = Task { [weak self] in
                let result = await task.run()
                self?.finished(id, with: result)
            }
        case .hls:
            let task = HLSTask(download: downloads[index], session: session, retryDelays: retryDelays, onProgress: onProgress)
            tasks[id] = task
            runners[id] = Task { [weak self] in
                let result = await task.run()
                self?.finished(id, with: result)
            }
        }
    }

    private func apply(_ progress: DownloadProgress, to id: UUID) {
        guard let index = downloads.firstIndex(where: { $0.id == id }), tasks[id] != nil else { return }
        self.progress[id] = progress
        downloads[index].segments = progress.segments
        if downloads[index].kind == .file { downloads[index].size = progress.total }
        downloads[index].mediaDone = progress.mediaDone
        downloads[index].mediaTotal = progress.mediaTotal
        if downloads[index].state.isRunning || progress.state.isRunning {
            downloads[index].state = progress.state
        }
    }

    private func finished(_ id: UUID, with result: Download) {
        tasks[id] = nil
        runners[id] = nil
        progress[id] = result.state.isRunning ? progress[id] : nil
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index] = result
        }
        log.notice("\(result.name, privacy: .public): \(String(describing: result.state), privacy: .public)")
        changed()
        pump()
    }

    private func changed() {
        onChange?()
    }
}


/// What the engine needs from a running task, whichever kind it is.
protocol Pausable: Sendable {
    func pause() async
    func cancel() async
}

extension DownloadTask: Pausable {}
extension HLSTask: Pausable {}
