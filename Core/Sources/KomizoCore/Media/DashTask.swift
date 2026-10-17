import Foundation

/// Downloads a DASH video track and audio track as two ordinary segmented downloads, then joins them into one MP4.
/// Progress counts the two parts; the record it returns looks like any other finished download.
public actor DashTask {
    private var download: Download
    private let connections: Int
    private let session: URLSession
    private let limiter: SpeedLimiter?
    private let retryDelays: [TimeInterval]
    private let onProgress: @Sendable (DownloadProgress) -> Void
    private var current: DownloadTask?
    private var paused = false
    private var cancelled = false

    public init(download: Download, connections: Int, session: URLSession, limiter: SpeedLimiter? = nil, retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays,
                onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.download = download
        self.connections = connections
        self.session = session
        self.limiter = limiter
        self.retryDelays = retryDelays
        self.onProgress = onProgress
    }

    public func run() async -> Download {
        guard let audioURL = download.audioURL else {
            download.state = .failed("This stream names no audio track.")
            emit()
            return download
        }
        let stem = (download.name as NSString).deletingPathExtension
        let videoPart = part(named: stem + " (video).mp4", url: download.url)
        let audioPart = part(named: stem + " (audio).mp4", url: audioURL)
        download.mediaTotal = 2
        download.mediaDone = 0
        download.state = .downloading
        emit()
        var finishedParts: [Download] = []
        for (index, piece) in [videoPart, audioPart].enumerated() {
            if paused || cancelled { break }
            // A first track that already carries sound needs no second one (some sites label a muxed file as "video").
            if index == 1, let first = finishedParts.first?.finalPath, let info = await MediaInfo.inspect(URL(fileURLWithPath: first)), info.hasVideo, info.hasAudio {
                return finish(with: first, discarding: finishedParts)
            }
            let task = DownloadTask(download: piece, connections: connections, session: session, limiter: limiter, retryDelays: retryDelays) { [weak self] progress in
                Task { await self?.progressed(progress, part: index) }
            }
            current = task
            let result = await task.run()
            current = nil
            switch result.state {
            case .finished: finishedParts.append(result)
            case .failed(let message):
                finishParts(finishedParts + [result], keep: false)
                download.state = .failed((index == 0 ? "Video track: " : "Audio track: ") + message)
                emit()
                return download
            default: break
            }
            download.mediaDone = finishedParts.count
        }
        if cancelled || paused {
            finishParts(finishedParts, keep: false)
            if cancelled, let own = download.partPath { try? FileManager.default.removeItem(atPath: own); download.partPath = nil }
            download.state = cancelled ? .cancelled : .paused
            download.mediaDone = nil
            emit()
            return download
        }
        guard finishedParts.count == 2, let v = finishedParts[0].finalPath, let a = finishedParts[1].finalPath else {
            download.state = .failed("A track did not finish.")
            emit()
            return download
        }
        let second = await MediaInfo.inspect(URL(fileURLWithPath: a))
        if second?.hasAudio != true {
            if second?.hasVideo == true, let first = await MediaInfo.inspect(URL(fileURLWithPath: v)), first.hasAudio, first.hasVideo {
                return finish(with: v, discarding: finishedParts)
            }
            finishParts(finishedParts, keep: false)
            download.state = .failed("The site offered no sound for this video (no audio track in either part).")
            emit()
            return download
        }
        // The engine claimed this name with an empty part file at add time; that claim is ours to ignore and remove.
        let ownPart = Filename.partName(for: download.name)
        let output = download.folder.appendingPathComponent(Filename.available(download.name, in: download.folder, ignoring: [ownPart]))
        do {
            _ = try await Muxer.join(video: URL(fileURLWithPath: v), audio: URL(fileURLWithPath: a), into: output)
            finishParts(finishedParts, keep: false)
            try? FileManager.default.removeItem(at: download.folder.appendingPathComponent(ownPart))
            download.finalPath = output.path
            download.partPath = nil
            download.size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? nil
            download.finished = Date()
            download.state = .finished
        } catch let failure as DownloadFailure {
            // The parts are left next to each other, so nothing downloaded is lost.
            download.state = .failed(failure.message + " The video and audio parts were kept.")
        } catch {
            download.state = .failed(error.localizedDescription)
        }
        emit()
        return download
    }

    /// A part that is already the whole video becomes the result; the other parts and the claimed name go.
    private func finish(with path: String, discarding parts: [Download]) -> Download {
        let ownPart = Filename.partName(for: download.name)
        let output = download.folder.appendingPathComponent(Filename.available(download.name, in: download.folder, ignoring: [ownPart]))
        do {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: output)
            finishParts(parts.filter { $0.finalPath != path }, keep: false)
            try? FileManager.default.removeItem(at: download.folder.appendingPathComponent(ownPart))
            download.finalPath = output.path
            download.partPath = nil
            download.size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? nil
            download.finished = Date()
            download.state = .finished
        } catch {
            download.state = .failed("Could not place the file: \(error.localizedDescription)")
        }
        emit()
        return download
    }

    public func pause() {
        guard !paused, !cancelled else { return }
        paused = true
        Task { await current?.pause() }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        Task { await current?.cancel() }
    }

    private func part(named name: String, url: URL) -> Download {
        var piece = Download(url: url, kind: .file, name: name, folder: download.folder, context: download.context)
        piece.id = UUID()
        return piece
    }

    private func finishParts(_ parts: [Download], keep: Bool) {
        guard !keep else { return }
        for part in parts {
            if let path = part.finalPath { try? FileManager.default.removeItem(atPath: path) }
            if let path = part.partPath { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    private func progressed(_ progress: DownloadProgress, part: Int) {
        download.segments = progress.segments
        onProgress(DownloadProgress(state: download.state, bytes: progress.bytes, total: progress.total, segments: progress.segments,
                                    bytesPerSecond: progress.bytesPerSecond, eta: progress.eta, mediaDone: download.mediaDone, mediaTotal: 2))
    }

    private func emit() {
        onProgress(DownloadProgress(state: download.state, bytes: download.bytesReceived, total: download.size, segments: download.segments,
                                    bytesPerSecond: 0, eta: nil, mediaDone: download.mediaDone, mediaTotal: download.mediaTotal))
    }
}
