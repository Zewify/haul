import Foundation

/// Runs one stream download, HLS or DASH, the way `DownloadTask` runs a file: finished, paused, cancelled or failed,
/// with a record to store. A stream whose sound comes separately is two tracks, saved one after the other into their
/// own part files and joined by `Muxer`. A pause keeps the segments saved so far; a resume carries on from them if
/// the stream is unchanged.
public actor StreamTask {
    private var download: Download
    private let fetcher: MediaFetcher
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private var running: Task<Void, Error>?
    /// Which track progress belongs to; a late report from a track that is done is ignored.
    private var currentTrack = 0
    private var paused = false
    private var cancelled = false

    public init(download: Download, session: URLSession, retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.download = download
        self.fetcher = MediaFetcher(context: download.context, session: session, retryDelays: retryDelays)
        self.onProgress = onProgress
    }

    public func run() async -> Download {
        download.state = .downloading
        emit()
        do {
            let task = Task { try await self.work() }
            running = task
            if paused || cancelled { task.cancel() }
            try await task.value
            running = nil
            download.finished = Date()
            download.state = .finished
        } catch is CancellationError {
            if cancelled {
                for path in download.trackPartPaths + [download.partPath].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
                download.partPath = nil
                download.mediaDone = nil
                download.mediaOffset = nil
                download.mediaTrack = nil
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

    private func work() async throws {
        let plan = try await StreamSource.plan(download.kind, url: download.url, fetcher: fetcher)
        if let audio = plan.audio {
            try await saveJoined(video: plan.video, audio: audio)
        } else {
            try await saveSingle(plan.video)
        }
        download.size = download.finalPath.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64) ?? nil }
    }

    /// Sound and picture in one track: the segments go straight into the download's own part file.
    private func saveSingle(_ track: StreamTrack) async throws {
        let part = PartFile(folder: download.folder, name: download.name)
        download.partPath = part.url.path
        download.mediaTrack = nil
        let skipping = part.length > 0 ? (download.mediaDone ?? 0) : 0
        try await save(track, into: part, track: 0, skipping: skipping, resumeOffset: download.mediaOffset ?? 0, before: 0, total: track.segments.count)
        let ext = track.fileExtension
        let finalName = download.name.hasSuffix("." + ext) ? download.name : download.name + "." + ext
        let destination = download.folder.appendingPathComponent(Filename.available(finalName, in: download.folder))
        try FileManager.default.moveItem(at: part.url, to: destination)
        download.finalPath = destination.path
        download.partPath = nil
    }

    /// Picture and sound apart: the video track, then the audio track, then one MP4 made of both without re-encoding.
    private func saveJoined(video: StreamTrack, audio: StreamTrack) async throws {
        let parts = download.trackParts
        let total = video.segments.count + audio.segments.count
        var track = download.mediaTrack ?? 0
        // The video part went missing while paused: there is nothing to carry on from.
        if track == 1 && parts.video.length == 0 { track = 0 }
        if track == 0 {
            download.mediaTrack = 0
            let skipping = parts.video.length > 0 ? (download.mediaDone ?? 0) : 0
            try await save(video, into: parts.video, track: 0, skipping: skipping, resumeOffset: download.mediaOffset ?? 0, before: 0, total: total)
            download.mediaDone = video.segments.count
            download.mediaOffset = 0
        }
        download.mediaTrack = 1
        currentTrack = 1
        let audioSkipping = parts.audio.length > 0 ? max(0, (download.mediaDone ?? 0) - video.segments.count) : 0
        try await save(audio, into: parts.audio, track: 1, skipping: audioSkipping, resumeOffset: download.mediaOffset ?? 0, before: video.segments.count, total: total)

        // AVFoundation tells formats apart by extension, so each part is renamed to what it is before the join.
        let stem = (download.name as NSString).deletingPathExtension
        let videoFile = download.folder.appendingPathComponent(Filename.available("\(stem) (video).\(video.fileExtension)", in: download.folder))
        try FileManager.default.moveItem(at: parts.video.url, to: videoFile)
        let audioFile = download.folder.appendingPathComponent(Filename.available("\(stem) (audio).\(audio.fileExtension)", in: download.folder))
        try FileManager.default.moveItem(at: parts.audio.url, to: audioFile)
        let ownPart = Filename.partName(for: download.name)
        let output = download.folder.appendingPathComponent(Filename.available(stem + ".mp4", in: download.folder, ignoring: [ownPart]))
        do {
            _ = try await Muxer.join(video: videoFile, audio: audioFile, into: output)
        } catch let failure as DownloadFailure {
            // The two parts stay next to each other, so nothing downloaded is lost.
            download.mediaTrack = nil
            throw DownloadFailure(failure.message + " The video and audio parts were kept.")
        }
        try? FileManager.default.removeItem(at: videoFile)
        try? FileManager.default.removeItem(at: audioFile)
        try? FileManager.default.removeItem(at: download.folder.appendingPathComponent(ownPart))
        download.finalPath = output.path
        download.partPath = nil
        download.mediaTrack = nil
        download.mediaDone = total
        download.mediaTotal = total
    }

    private func save(_ stream: StreamTrack, into part: PartFile, track: Int, skipping: Int, resumeOffset: Int64, before: Int, total: Int) async throws {
        currentTrack = track
        try part.prepare(size: nil)
        let downloader = SegmentDownloader(track: stream, fetcher: fetcher, partFile: part) { [weak self] done, _, offset in
            Task { await self?.progressed(track: track, done: before + done, total: total, offset: offset) }
        }
        try await downloader.run(skipping: skipping, resumeOffset: resumeOffset)
    }

    /// `done`, `total` and `offset` arrive together, so what is saved is always a consistent pair, even if it
    /// trails the file by a batch; the resume truncates the file back to the offset.
    private func progressed(track: Int, done: Int, total: Int, offset: Int64) {
        guard track == currentTrack, download.state == .downloading else { return }
        download.mediaDone = done
        download.mediaTotal = total
        download.mediaOffset = offset
        download.segments = [Segment(start: 0, end: Int64.max - 1, written: offset)]
        emit()
    }

    private func emit() {
        onProgress(DownloadProgress(state: download.state, bytes: download.bytesReceived, total: nil, segments: download.segments,
                                    bytesPerSecond: 0, eta: nil, mediaDone: download.mediaDone, mediaTotal: download.mediaTotal,
                                    mediaOffset: download.mediaOffset, mediaTrack: download.mediaTrack))
    }
}
