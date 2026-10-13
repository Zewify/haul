import Foundation
import os

/// A snapshot of a running download for the UI: about ten a second while bytes flow, and on every state change.
public struct DownloadProgress: Sendable, Hashable {
    public var state: DownloadState
    public var bytes: Int64
    public var total: Int64?
    public var segments: [Segment]
    public var bytesPerSecond: Double
    public var eta: TimeInterval?
    public var mediaDone: Int?
    public var mediaTotal: Int?

    public init(state: DownloadState, bytes: Int64, total: Int64?, segments: [Segment], bytesPerSecond: Double, eta: TimeInterval?,
                mediaDone: Int? = nil, mediaTotal: Int? = nil) {
        self.state = state
        self.bytes = bytes
        self.total = total
        self.segments = segments
        self.bytesPerSecond = bytesPerSecond
        self.eta = eta
        self.mediaDone = mediaDone
        self.mediaTotal = mediaTotal
    }
}

/// Stops the whole download: the server said no, the disk said no, or a segment ran out of retries.
public struct DownloadFailure: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Runs one download from probe to finished file: segments in parallel, retries with backoff, rebalancing,
/// pause and resume, and a restart when the file changes on the server.
public actor DownloadTask {
    public static let defaultRetryDelays: [TimeInterval] = [1, 2, 4, 8, 16]
    /// How far back the speed estimate looks.
    static let speedWindow: TimeInterval = 3
    static let progressInterval: TimeInterval = 0.1

    private var download: Download
    private let connections: Int
    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private let log = Logger(subsystem: "com.zewify.haul", category: "download")

    private var partFile: PartFile?
    private var handles: [Int: FileHandle] = [:]
    private var fetching: Task<Void, Error>?
    private var paused = false
    private var cancelled = false
    private var samples: [(time: Date, bytes: Int64)] = []
    private var lastEmit = Date.distantPast

    private enum SegmentError: Error {
        /// The validator or size no longer matches, or the server stopped honouring ranges: start over once.
        case restart(String)
        /// Worth another try.
        case transient(String)
    }

    public init(download: Download, connections: Int, session: URLSession,
                retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.download = download
        self.connections = max(1, connections)
        self.session = session
        self.retryDelays = retryDelays
        self.onProgress = onProgress
    }

    public var current: Download { download }

    // MARK: Control

    /// Runs until the download is finished, paused, cancelled or failed, and returns the record to store.
    public func run() async -> Download {
        do {
            try await probeAndPlan()
            var restarted = false
            while true {
                do {
                    try await fetchAll()
                    break
                } catch SegmentError.restart(let reason) where !restarted {
                    log.notice("restarting \(self.download.name, privacy: .public): \(reason, privacy: .public)")
                    restarted = true
                    download.segments = []
                    partFile?.remove()
                    try await probeAndPlan()
                } catch SegmentError.restart(let reason) {
                    throw DownloadFailure("The file keeps changing on the server (\(reason)).")
                }
            }
            closeHandles()
            let final = try partFile!.finish()
            download.finalPath = final.path
            download.partPath = nil
            download.finished = Date()
            setState(.finished)
        } catch is CancellationError {
            closeHandles()
            if cancelled {
                partFile?.remove()
                download.partPath = nil
                download.segments = download.resumable ? download.segments : []
                setState(.cancelled)
            } else {
                setState(.paused)
            }
        } catch let failure as DownloadFailure {
            fail(failure.message)
        } catch let error as ProbeError {
            switch error {
            case .status(let code): fail("The server answered \(code).")
            case .notHTTP: fail("Only http and https links can be downloaded.")
            }
        } catch {
            fail(error.localizedDescription)
        }
        return download
    }

    /// A failure keeps the part file for a retry, unless nothing was ever written to it, in which case it is litter.
    private func fail(_ message: String) {
        closeHandles()
        if download.bytesReceived == 0 {
            (partFile ?? PartFile(folder: download.folder, name: download.name)).remove()
            download.partPath = nil
            download.segments = []
        }
        setState(.failed(message))
    }

    public func pause() {
        guard !paused, !cancelled else { return }
        paused = true
        fetching?.cancel()
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        fetching?.cancel()
    }

    // MARK: Probe and plan

    private func probeAndPlan() async throws {
        setState(.probing)
        let probe = try await Probe.run(download.url, context: download.context, session: session)
        let resumable = probe.acceptsRanges && probe.size != nil
        if download.name.isEmpty { download.name = probe.suggestedName }
        download.finalURL = probe.finalURL
        download.contentType = probe.contentType
        let part = PartFile(folder: download.folder, name: download.name)
        partFile = part
        download.partPath = part.url.path

        let canResume = !download.segments.isEmpty && download.resumable && resumable
            && download.size == probe.size && download.validator == probe.validator && part.length == probe.size
        download.size = probe.size
        download.validator = probe.validator
        download.resumable = resumable
        if canResume {
            for index in download.segments.indices {
                download.segments[index].written = min(download.segments[index].written, download.segments[index].length)
            }
        } else {
            part.remove()
            if resumable, let size = probe.size {
                download.segments = SegmentPlanner.plan(size: size, connections: connections)
            } else {
                download.segments = [Segment(start: 0, end: probe.size.map { max(0, $0 - 1) } ?? Int64.max - 1)]
            }
        }
        do {
            try part.prepare(size: resumable ? probe.size : nil)
        } catch {
            throw DownloadFailure("Cannot write to \(download.folder.lastPathComponent): \(error.localizedDescription)")
        }
        samples.removeAll()
        setState(.downloading)
    }

    // MARK: Fetching

    private func fetchAll() async throws {
        let task = Task { try await self.fetchLoop() }
        fetching = task
        defer { fetching = nil }
        try await task.value
    }

    /// Keeps `connections` segments in flight; when one finishes and another has a long tail, splits that tail.
    private func fetchLoop() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            var running = Set<Int>()
            func startPending() {
                let segments = download.segments
                for index in segments.indices where running.count < connections && !running.contains(index) && !segments[index].isComplete {
                    running.insert(index)
                    group.addTask { try await self.fetchSegment(index); return index }
                }
            }
            startPending()
            while !running.isEmpty {
                guard let done = try await group.next() else { break }
                running.remove(done)
                startPending()
                if download.resumable, running.count < connections,
                   let split = SegmentPlanner.rebalance(download.segments.enumerated().map { running.contains($0.offset) ? $0.element : Segment(start: 0, end: 0, written: 1) }) {
                    download.segments[split.donor].end = split.donorEnd
                    download.segments.append(split.newSegment)
                    startPending()
                }
            }
            try Task.checkCancellation()
        }
    }

    private func fetchSegment(_ index: Int) async throws {
        var attempt = 0
        while true {
            do {
                try await fetchOnce(index)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch SegmentError.transient(let reason) {
                guard attempt < retryDelays.count else {
                    throw DownloadFailure("Gave up after \(attempt) retries: \(reason)")
                }
                log.notice("segment \(index) retry \(attempt + 1): \(reason, privacy: .public)")
                try await Task.sleep(for: .seconds(retryDelays[attempt]))
                attempt += 1
                if !download.resumable { download.segments[index].written = 0 }
            }
        }
    }

    private func fetchOnce(_ index: Int) async throws {
        guard let finalURL = download.finalURL, let part = partFile else { throw DownloadFailure("Not planned") }
        let segment = download.segments[index]
        if segment.isComplete { return }
        var request = URLRequest(url: finalURL)
        request.timeoutInterval = 30
        for (key, value) in download.context.allHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if download.resumable {
            request.setValue("bytes=\(segment.position)-\(segment.end)", forHTTPHeaderField: "Range")
        }
        let handle: FileHandle
        do {
            handle = try part.writer()
        } catch {
            throw DownloadFailure("Cannot open the file: \(error.localizedDescription)")
        }
        handles[index] = handle
        defer { try? handle.close(); handles[index] = nil }

        var sawResponse = false
        do {
            for try await event in HTTPStream.open(request, session: session) {
                switch event {
                case .response(let response):
                    sawResponse = true
                    try validate(response, for: index)
                case .data(let data):
                    if try await write(data, to: index, handle: handle) == .stop { return }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SegmentError {
            throw error
        } catch let error as DownloadFailure {
            throw error
        } catch {
            throw SegmentError.transient(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard sawResponse else { throw SegmentError.transient("No response") }
        let after = download.segments[index]
        if download.size == nil {
            // An unsized stream ended: that was the whole file.
            download.segments[index].end = max(0, after.written - 1)
            download.size = after.written
            emit(force: true)
        } else if !after.isComplete {
            throw SegmentError.transient("Connection closed after \(after.written) of \(after.length) bytes")
        }
    }

    private func validate(_ response: HTTPURLResponse, for index: Int) throws {
        let segment = download.segments[index]
        switch response.statusCode {
        case 206:
            guard download.resumable, let range = response.value(forHTTPHeaderField: "Content-Range"),
                  let start = Self.rangeStart(range), start == segment.position else {
                throw SegmentError.restart("Unexpected Content-Range")
            }
        case 200:
            if download.resumable && (segment.position > 0 || download.segments.count > 1) {
                throw SegmentError.restart("The server stopped honouring ranges")
            }
        case 416:
            throw SegmentError.restart("The file's size changed")
        case 408, 425, 429, 500...599:
            throw SegmentError.transient("The server answered \(response.statusCode)")
        default:
            throw DownloadFailure("The server answered \(response.statusCode).")
        }
        if let expected = download.validator,
           let actual = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified"),
           expected != actual {
            throw SegmentError.restart("The file changed on the server")
        }
    }

    static func rangeStart(_ contentRange: String) -> Int64? {
        // bytes 100-199/1000
        let spec = contentRange.trimmingCharacters(in: .whitespaces).dropFirst("bytes".count).trimmingCharacters(in: .whitespaces)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        return Int64(spec[..<dash])
    }

    private enum WriteOutcome { case `continue`, stop }

    /// Writes a chunk at the segment's position, never past its end (which rebalancing may have pulled in).
    private func write(_ data: Data, to index: Int, handle: FileHandle) async throws -> WriteOutcome {
        let segment = download.segments[index]
        let room = segment.end - segment.position + 1
        guard room > 0 else { return .stop }
        let take = Int(min(room, Int64(data.count)))
        do {
            try handle.seek(toOffset: UInt64(segment.position))
            try handle.write(contentsOf: take == data.count ? data : data.prefix(take))
        } catch {
            throw DownloadFailure("Writing failed: \(error.localizedDescription)")
        }
        download.segments[index].written += Int64(take)
        emit(force: false)
        return take < data.count || download.segments[index].isComplete ? .stop : .continue
    }

    // MARK: DownloadProgress

    private func setState(_ state: DownloadState) {
        download.state = state
        emit(force: true)
    }

    private func emit(force: Bool) {
        let now = Date()
        let bytes = download.bytesReceived
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.speedWindow }
        guard force || now.timeIntervalSince(lastEmit) >= Self.progressInterval else { return }
        lastEmit = now
        var speed = 0.0
        if let first = samples.first, now.timeIntervalSince(first.time) > 0.2 {
            speed = Double(bytes - first.bytes) / now.timeIntervalSince(first.time)
        }
        var eta: TimeInterval?
        if let total = download.size, speed > 0, download.state.isRunning {
            eta = Double(total - bytes) / speed
        }
        onProgress(DownloadProgress(state: download.state, bytes: bytes, total: download.size, segments: download.segments,
                            bytesPerSecond: download.state.isRunning ? speed : 0, eta: eta))
    }

    private func closeHandles() {
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }
}
