import Foundation

/// One piece of a stream to fetch: its URL, the bytes of it when it is a range of a bigger file, and how it is encrypted.
public struct StreamSegment: Hashable, Sendable {
    public var uri: URL
    public var range: ClosedRange<Int64>?
    public var duration: Double
    public var key: HLS.Key?
    public var sequence: Int

    public init(uri: URL, range: ClosedRange<Int64>? = nil, duration: Double = 0, key: HLS.Key? = nil, sequence: Int = 0) {
        self.uri = uri
        self.range = range
        self.duration = duration
        self.key = key
        self.sequence = sequence
    }
}

/// The segments of one track, in order, after its init segment when it has one.
public struct StreamTrack: Hashable, Sendable {
    public var segments: [StreamSegment]
    public var map: StreamSegment?

    public init(segments: [StreamSegment], map: StreamSegment? = nil) {
        self.segments = segments
        self.map = map
    }

    /// What the joined segments make: fragmented MP4, packed AAC audio, or MPEG-TS.
    public var fileExtension: String {
        if map != nil { return "mp4" }
        let extensions = Set(segments.map { $0.uri.pathExtension.lowercased() })
        if !extensions.isDisjoint(with: ["m4s", "mp4", "m4a", "m4v", "cmfv", "cmfa"]) { return "mp4" }
        if extensions == ["aac"] { return "aac" }
        return "ts"
    }

    /// The track is one whole file, as a DASH site with `SegmentBase` serves it: worth a segmented file download instead.
    public var wholeFile: URL? {
        guard map == nil, segments.count == 1, segments[0].range == nil, segments[0].key == nil else { return nil }
        return segments[0].uri
    }
}

/// A stream resolved to what has to be fetched: the video track, and the audio track when the site keeps sound apart.
public struct StreamPlan: Hashable, Sendable {
    public var video: StreamTrack
    public var audio: StreamTrack?

    public init(video: StreamTrack, audio: StreamTrack? = nil) {
        self.video = video
        self.audio = audio
    }
}

/// Fetches playlists, manifests, keys and segments with the browser's headers, retrying what a retry can fix,
/// within the speed limit when there is one.
public struct MediaFetcher: Sendable {
    public var context: RequestContext
    public var session: URLSession
    public var limiter: SpeedLimiter?
    public var retryDelays: [TimeInterval]

    public init(context: RequestContext, session: URLSession, limiter: SpeedLimiter? = nil, retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays) {
        self.context = context
        self.session = session
        self.limiter = limiter
        self.retryDelays = retryDelays
    }

    public func data(_ url: URL, range: ClosedRange<Int64>? = nil) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            for (key, value) in context.allHeaders { request.setValue(value, forHTTPHeaderField: key) }
            if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
            do {
                var response: HTTPURLResponse?
                var data = Data()
                reading: for try await event in HTTPStream.open(request, session: session, original: url) {
                    switch event {
                    case .response(let http): response = http
                    case .data(let chunk, let consumed):
                        defer { consumed() }
                        // A server that ignores Range would send the whole file; stop once the range is in hand.
                        if let range, response?.statusCode == 200, Int64(data.count) > range.upperBound { break reading }
                        if let limiter, limiter.bytesPerSecond != nil {
                            // Paid for a slice at a time, as a file download is, so a stream keeps to the cap too.
                            var offset = chunk.startIndex
                            while offset < chunk.endIndex {
                                let end = min(offset + SpeedLimiter.slice, chunk.endIndex)
                                await limiter.spend(end - offset)
                                try Task.checkCancellation()
                                data.append(chunk[offset..<end])
                                offset = end
                            }
                        } else {
                            data.append(chunk)
                        }
                    }
                }
                guard let http = response else { throw DownloadFailure("Not an HTTP response.") }
                switch http.statusCode {
                case 206: return data
                case 200...299:
                    // A server that ignores Range sends the whole file; the range is then cut out of it here.
                    guard let range else { return data }
                    guard Int64(data.count) > range.upperBound else { throw DownloadFailure("\(url.lastPathComponent) is shorter than the stream says.") }
                    return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
                case 408, 425, 429, 500...599: throw RetryableError(status: http.statusCode)
                default: throw DownloadFailure("The server answered \(http.statusCode) for \(url.lastPathComponent).")
                }
            } catch let error as DownloadFailure {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A pause cancels the request mid-flight; URLSession reports that as a network error, not a cancellation.
                if Task.isCancelled { throw CancellationError() }
                guard attempt < retryDelays.count else { throw DownloadFailure("Gave up on \(url.lastPathComponent): \(error.localizedDescription)") }
                try await Task.sleep(for: .seconds(retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    private struct RetryableError: Error {
        let status: Int
    }
}

/// Reads an HLS playlist or a DASH manifest and says what to download.
public enum StreamSource {
    /// A playlist that is still being written: there is no end to download to.
    public static let liveStream = DownloadFailure("This is a live stream; Haul saves finished videos.")

    public static func plan(_ kind: DownloadKind, url: URL, fetcher: MediaFetcher) async throws -> StreamPlan {
        switch kind {
        case .mpd: try await dashPlan(url, fetcher: fetcher)
        default: try await hlsPlan(url, fetcher: fetcher)
        }
    }

    static func hlsPlan(_ url: URL, fetcher: MediaFetcher) async throws -> StreamPlan {
        switch try await playlist(url, fetcher: fetcher) {
        case .media(let segments, let map, let endList):
            guard endList else { throw liveStream }
            return StreamPlan(video: StreamTrack(segments: segments, map: map))
        case .master(let variants, let renditions):
            guard let best = HLS.best(of: variants) else { throw DownloadFailure("The playlist lists no streams.") }
            guard case .media(let segments, let map, let endList) = try await playlist(best.uri, fetcher: fetcher) else {
                throw DownloadFailure("The playlist only points at other playlists.")
            }
            guard endList else { throw liveStream }
            var plan = StreamPlan(video: StreamTrack(segments: segments, map: map))
            if let rendition = HLS.audio(for: best, in: renditions), let audioURL = rendition.uri {
                guard case .media(let audioSegments, let audioMap, _) = try await playlist(audioURL, fetcher: fetcher) else {
                    throw DownloadFailure("The stream's audio playlist points at other playlists.")
                }
                plan.audio = StreamTrack(segments: audioSegments, map: audioMap)
            }
            return plan
        }
    }

    private static func playlist(_ url: URL, fetcher: MediaFetcher) async throws -> HLS.Playlist {
        let text = String(decoding: try await fetcher.data(url), as: UTF8.self)
        do {
            return try HLS.parse(text, base: url)
        } catch HLS.ParseError.drm {
            throw DownloadFailure("This stream is protected (DRM) and cannot be saved.")
        } catch {
            throw DownloadFailure("Not an HLS playlist.")
        }
    }

    static func dashPlan(_ url: URL, fetcher: MediaFetcher) async throws -> StreamPlan {
        let xml = try await fetcher.data(url)
        do {
            return try DASHManifest.plan(xml, base: url)
        } catch let error as DASHManifest.ParseError {
            throw DownloadFailure(error.message)
        }
    }
}
