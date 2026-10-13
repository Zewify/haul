import Foundation

/// Runs one HLS download the way `DownloadTask` runs a file: finished, paused, cancelled or failed, with a
/// record to store. A pause keeps the segments saved so far; a resume carries on from them if the stream is unchanged.
public actor HLSTask {
    private var download: Download
    private let session: URLSession
    private let retryDelays: [TimeInterval]
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private var running: Task<String, Error>?
    private var paused = false
    private var cancelled = false

    public init(download: Download, session: URLSession, retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.download = download
        self.session = session
        self.retryDelays = retryDelays
        self.onProgress = onProgress
    }

    public func run() async -> Download {
        let part = PartFile(folder: download.folder, name: download.name)
        download.partPath = part.url.path
        download.state = .downloading
        emit()
        let skipping = part.length > 0 ? (download.mediaDone ?? 0) : 0
        if skipping == 0 { part.remove() }
        do {
            try part.prepare(size: nil)
            let downloader = HLSDownloader(url: download.url, context: download.context, session: session, partFile: part,
                                           retryDelays: retryDelays) { [weak self] done, total in
                Task { await self?.progressed(done, total, bytes: part.length) }
            }
            let task = Task { try await downloader.run(skipping: skipping) }
            running = task
            let ext = try await task.value
            running = nil
            download.mediaTotal = await downloader.segmentCount
            download.mediaDone = download.mediaTotal
            let finalName = download.name.hasSuffix("." + ext) ? download.name : download.name + "." + ext
            let destination = download.folder.appendingPathComponent(Filename.available(finalName, in: download.folder))
            try FileManager.default.moveItem(at: part.url, to: destination)
            download.finalPath = destination.path
            download.partPath = nil
            download.size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            download.finished = Date()
            download.state = .finished
        } catch is CancellationError {
            if cancelled {
                part.remove()
                download.partPath = nil
                download.mediaDone = nil
                download.state = .cancelled
            } else {
                download.state = .paused
            }
        } catch let failure as DownloadFailure {
            download.state = .failed(failure.message)
        } catch {
            download.state = .failed(error.localizedDescription)
        }
        emit()
        return download
    }

    public func pause() {
        guard !paused, !cancelled else { return }
        paused = true
        running?.cancel()
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        running?.cancel()
    }

    private func progressed(_ done: Int, _ total: Int, bytes: Int64) {
        download.mediaDone = done
        download.mediaTotal = total
        download.segments = [Segment(start: 0, end: Int64.max - 1, written: bytes)]
        emit()
    }

    private func emit() {
        onProgress(DownloadProgress(state: download.state, bytes: download.bytesReceived, total: nil, segments: download.segments,
                                    bytesPerSecond: 0, eta: nil, mediaDone: download.mediaDone, mediaTotal: download.mediaTotal))
    }
}
