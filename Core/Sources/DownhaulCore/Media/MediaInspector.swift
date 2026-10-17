import Foundation

/// What Downhaul can learn about a page's media without downloading it, for the extension to tell which item is the
/// video being watched and which video-only and audio-only files belong together.
public struct InspectedMedia: Codable, Sendable, Hashable {
    public var url: String
    /// Seconds; nil when it cannot be told.
    public var duration: Double?
    /// Whether it carries picture and sound; nil when it cannot be told (a stream whose sound may be muxed in).
    public var video: Bool?
    public var audio: Bool?
    public var width: Int?
    public var height: Int?
    /// A live stream, which has no end to download to.
    public var live: Bool?
    /// Why Downhaul could not read it (a refused or one-time link); a grab of it would fail the same way.
    public var error: String?

    public init(url: String, duration: Double? = nil, video: Bool? = nil, audio: Bool? = nil, width: Int? = nil, height: Int? = nil, live: Bool? = nil) {
        self.url = url
        self.duration = duration
        self.video = video
        self.audio = audio
        self.width = width
        self.height = height
        self.live = live
    }
}

public enum MediaInspector {
    /// The most of a file's head Downhaul reads to find its `moov`; a bigger index is not worth the wait.
    static let maxHead = 16 << 20

    /// Reads a file's head (its `moov`), or a playlist or manifest, and says what it holds. Never throws: what cannot
    /// be read is simply left unknown.
    public static func inspect(_ url: URL, kind: String, fetcher: MediaFetcher) async -> InspectedMedia {
        var result = InspectedMedia(url: url.absoluteString)
        switch kind {
        case "hls", "mpd":
            do {
                let plan = try await StreamSource.plan(kind == "mpd" ? .mpd : .hls, url: url, fetcher: fetcher)
                result.duration = plan.video.segments.reduce(0) { $0 + $1.duration }
                result.video = true
                if plan.audio != nil { result.audio = true }
            } catch let failure as DownloadFailure where failure == StreamSource.liveStream {
                result.live = true
            } catch let failure as DownloadFailure {
                result.error = failure.message
            } catch {
                result.error = error.localizedDescription
            }
        default:
            let head: Data
            do {
                head = try await fetcher.data(url, range: 0...(MP4Probe.headLength - 1))
            } catch let failure as DownloadFailure {
                result.error = failure.message
                return result
            } catch {
                result.error = error.localizedDescription
                return result
            }
            var whole = head
            if let needed = MP4Probe.requiredLength(head), needed <= maxHead, let more = try? await fetcher.data(url, range: 0...Int64(needed - 1)) {
                whole = more
            }
            guard let probe = MP4Probe.read(whole) else { return result }
            result.duration = probe.duration
            result.video = probe.hasVideo
            result.audio = probe.hasAudio
            if probe.hasVideo { result.width = probe.width; result.height = probe.height }
        }
        return result
    }
}
