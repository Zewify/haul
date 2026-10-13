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
        return all
    }
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
    /// The `.haulpart` file while downloading.
    public var partPath: String?
    /// The finished file.
    public var finalPath: String?
    /// For an HLS download: segments saved and segments in the stream.
    public var mediaDone: Int?
    public var mediaTotal: Int?

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

    public var bytesReceived: Int64 { segments.reduce(0) { $0 + $1.written } }

    /// 0...1 while the size is known (segments, for HLS), nil otherwise.
    public var fraction: Double? {
        if state == .finished { return 1 }
        if kind == .hls {
            guard let mediaDone, let mediaTotal, mediaTotal > 0 else { return nil }
            return min(1, Double(mediaDone) / Double(mediaTotal))
        }
        guard let size, size > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(size))
    }
}
