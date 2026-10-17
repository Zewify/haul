import Foundation

/// What the browser knew when it handed a download over, so the engine can fetch the file as the browser would have.
public struct RequestContext: Codable, Hashable, Sendable {
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    public var headers: [String: String]

    public init(referrer: String? = nil, cookies: String? = nil, userAgent: String? = nil, headers: [String: String] = [:]) {
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.headers = headers
    }

    /// The headers every request for this download carries.
    public var allHeaders: [String: String] {
        var all = headers
        if let referrer { all["Referer"] = referrer }
        if let cookies, !cookies.isEmpty { all["Cookie"] = cookies }
        if let userAgent { all["User-Agent"] = userAgent }
        all["Accept-Encoding"] = "identity"
        return all
    }

    /// The headers for a request to `url`: the site's cookies only go to the site they came from, never to a
    /// CDN a redirect led to, as a browser would do.
    public func headers(for url: URL, original: URL) -> [String: String] {
        var all = allHeaders
        if Self.host(url) != Self.host(original) { all["Cookie"] = nil }
        return all
    }

    static func host(_ url: URL) -> String { (url.host ?? "").lowercased() }
}

/// One byte range of a download, `start...end` inclusive, and how much of it has reached the disk.
public struct Segment: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var written: Int64

    public init(start: Int64, end: Int64, written: Int64 = 0) {
        self.start = start
        self.end = end
        self.written = written
    }

    public var length: Int64 { end - start + 1 }
    public var remaining: Int64 { max(0, length - written) }
    public var isComplete: Bool { written >= length }
    /// Where the next byte goes.
    public var position: Int64 { start + written }
}

public enum DownloadState: Codable, Hashable, Sendable {
    case queued, probing, downloading, paused, finished, cancelled
    case failed(String)

    /// Queued or running: the queue counts these and Pause All touches them.
    public var isActive: Bool {
        switch self {
        case .queued, .probing, .downloading: true
        case .paused, .finished, .cancelled, .failed: false
        }
    }

    public var isRunning: Bool {
        switch self {
        case .probing, .downloading: true
        default: false
        }
    }
}

public enum DownloadKind: String, Codable, Sendable {
    case file, hls
    /// A video track and an audio track from a DASH site, downloaded separately and joined into one file.
    case dash
    /// A DASH manifest (MPD): the segments of its best video and audio, fetched like HLS and joined.
    case mpd

    /// HLS or a DASH manifest: fetched segment by segment from a playlist, counted in segments.
    public var isStream: Bool { self == .hls || self == .mpd }
}

/// One download, as the library stores it. Everything the engine needs to resume it is here.
public struct Download: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    /// Where the probe ended up after redirects; segments are fetched from here.
    public var finalURL: URL?
    public var kind: DownloadKind
    /// The filename the finished file gets.
    public var name: String
    public var folder: URL
    public var size: Int64?
    public var context: RequestContext
    public var state: DownloadState
    public var segments: [Segment]
    /// Whether the server honoured ranges; without it a pause starts over.
    public var resumable: Bool
    /// The ETag or Last-Modified the probe saw; a change means the file changed and the download restarts.
    public var validator: String?
    public var contentType: String?
    public var added: Date
    public var finished: Date?
    /// The `.komizopart` file while downloading.
    public var partPath: String?
    /// The finished file.
    public var finalPath: String?
    /// For a stream: segments saved, segments in the stream, and the byte the next segment goes at in the current part.
    public var mediaDone: Int?
    public var mediaTotal: Int?
    public var mediaOffset: Int64?
    /// For a stream whose sound comes separately: 0 while the video track downloads, 1 for the audio track.
    public var mediaTrack: Int?
    /// A security-scoped bookmark for a folder chosen for this download alone, so the sandbox lets the app back in.
    public var folderBookmark: Data?
    /// For a DASH download: where the audio track comes from (the video track is `url`).
    public var audioURL: URL?
    /// Whether this came through the grabber; finished media is inspected and `mediaNote` set when it has no sound.
    public var media: Bool = false
    public var mediaNote: String?

    public init(id: UUID = UUID(), url: URL, kind: DownloadKind = .file, name: String, folder: URL,
                context: RequestContext = RequestContext(), added: Date = Date()) {
        self.id = id
        self.url = url
        self.kind = kind
        self.name = name
        self.folder = folder
        self.context = context
        self.state = .queued
        self.segments = []
        self.resumable = false
        self.added = added
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, finalURL, kind, name, folder, size, context, state, segments, resumable, validator, contentType, added, finished,
             partPath, finalPath, mediaDone, mediaTotal, mediaOffset, mediaTrack, folderBookmark, audioURL, media, mediaNote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        finalURL = try c.decodeIfPresent(URL.self, forKey: .finalURL)
        kind = try c.decodeIfPresent(DownloadKind.self, forKey: .kind) ?? .file
        name = try c.decode(String.self, forKey: .name)
        folder = try c.decode(URL.self, forKey: .folder)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        context = try c.decodeIfPresent(RequestContext.self, forKey: .context) ?? RequestContext()
        state = try c.decodeIfPresent(DownloadState.self, forKey: .state) ?? .paused
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        resumable = try c.decodeIfPresent(Bool.self, forKey: .resumable) ?? false
        validator = try c.decodeIfPresent(String.self, forKey: .validator)
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        finished = try c.decodeIfPresent(Date.self, forKey: .finished)
        partPath = try c.decodeIfPresent(String.self, forKey: .partPath)
        finalPath = try c.decodeIfPresent(String.self, forKey: .finalPath)
        mediaDone = try c.decodeIfPresent(Int.self, forKey: .mediaDone)
        mediaTotal = try c.decodeIfPresent(Int.self, forKey: .mediaTotal)
        mediaOffset = try c.decodeIfPresent(Int64.self, forKey: .mediaOffset)
        mediaTrack = try c.decodeIfPresent(Int.self, forKey: .mediaTrack)
        folderBookmark = try c.decodeIfPresent(Data.self, forKey: .folderBookmark)
        audioURL = try c.decodeIfPresent(URL.self, forKey: .audioURL)
        media = try c.decodeIfPresent(Bool.self, forKey: .media) ?? false
        mediaNote = try c.decodeIfPresent(String.self, forKey: .mediaNote)
    }

    public var bytesReceived: Int64 { segments.reduce(0) { $0 + $1.written } }

    /// The part files of a stream saved as two tracks; they go with the download when it is cancelled or removed.
    public var trackParts: (video: PartFile, audio: PartFile) {
        let stem = (name as NSString).deletingPathExtension
        return (PartFile(folder: folder, name: stem + " (video)"), PartFile(folder: folder, name: stem + " (audio)"))
    }

    public var trackPartPaths: [String] {
        guard kind.isStream else { return [] }
        return [trackParts.video.url.path, trackParts.audio.url.path]
    }

    /// 0...1 while the size is known (segments, for a stream), nil otherwise.
    public var fraction: Double? {
        if state == .finished { return 1 }
        if kind.isStream || kind == .dash {
            guard let mediaDone, let mediaTotal, mediaTotal > 0 else { return nil }
            return min(1, Double(mediaDone) / Double(mediaTotal))
        }
        guard let size, size > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(size))
    }
}
