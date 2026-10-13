import CommonCrypto
import Foundation

/// Saves a finished HLS stream as one file: the highest-bandwidth variant, its segments fetched a few at a time
/// and appended in order, AES-128 segments decrypted. Returns the file extension the result should have.
public actor HLSDownloader {
    private let url: URL
    private let context: RequestContext
    private let session: URLSession
    private let partFile: PartFile
    private let parallel: Int
    private let retryDelays: [TimeInterval]
    /// Segments done, segments in all, and the byte offset the file is complete up to.
    private let onProgress: @Sendable (Int, Int, Int64) -> Void
    private var keys: [URL: Data] = [:]
    /// How many segments the stream has, once the playlist is read.
    public private(set) var segmentCount = 0

    public init(url: URL, context: RequestContext, session: URLSession, partFile: PartFile, parallel: Int = 4,
                retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays, onProgress: @escaping @Sendable (Int, Int, Int64) -> Void) {
        self.url = url
        self.context = context
        self.session = session
        self.partFile = partFile
        self.parallel = max(1, parallel)
        self.retryDelays = retryDelays
        self.onProgress = onProgress
    }

    /// `skipping` segments already in the part file lets a paused download carry on; `resumeOffset` is the byte
    /// those segments end at, and anything past it (a segment half written when the app died) is cut off.
    public func run(skipping: Int = 0, resumeOffset: Int64 = 0) async throws -> String {
        let (segments, map) = try await resolve()
        let handle: FileHandle
        do {
            handle = try partFile.writer()
        } catch {
            throw DownloadFailure("Cannot open the file: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var done = 0
        let total = segments.count
        segmentCount = total
        var skipping = skipping
        if skipping > total || resumeOffset <= 0 {
            // The stream has fewer segments than were saved, or nothing reliable was saved: start over.
            skipping = 0
        }
        var offset: Int64 = skipping == 0 ? 0 : resumeOffset
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        onProgress(skipping, total, offset)
        if skipping == 0, let map {
            let initData = try await fetch(map)
            try handle.write(contentsOf: initData)
            offset += Int64(initData.count)
        }
        var index = skipping
        done = skipping
        while index < total {
            let batch = Array(segments[index..<min(index + parallel, total)])
            let datas: [Data] = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (offset, segment) in batch.enumerated() {
                    group.addTask { (offset, try await self.fetchSegment(segment)) }
                }
                var results = [Data?](repeating: nil, count: batch.count)
                for try await (offset, data) in group { results[offset] = data }
                return results.map { $0! }
            }
            for data in datas {
                do { try handle.write(contentsOf: data) } catch { throw DownloadFailure("Writing failed: \(error.localizedDescription)") }
                offset += Int64(data.count)
            }
            index += batch.count
            done += batch.count
            onProgress(done, total, offset)
        }
        let fragmented = map != nil || segments.contains { ["m4s", "mp4"].contains($0.uri.pathExtension.lowercased()) }
        return fragmented ? "mp4" : "ts"
    }

    /// The media playlist's segments, following a master playlist to its best variant.
    private func resolve() async throws -> ([HLS.MediaSegment], URL?) {
        var playlistURL = url
        for _ in 0..<2 {
            let text = String(decoding: try await fetch(playlistURL), as: UTF8.self)
            let playlist: HLS.Playlist
            do {
                playlist = try HLS.parse(text, base: playlistURL)
            } catch HLS.ParseError.drm {
                throw DownloadFailure("This stream is protected (DRM) and cannot be saved.")
            } catch {
                throw DownloadFailure("Not an HLS playlist.")
            }
            switch playlist {
            case .master(let variants):
                guard let best = HLS.best(of: variants) else { throw DownloadFailure("The playlist lists no streams.") }
                playlistURL = best.uri
            case .media(let segments, let map, _):
                return (segments, map)
            }
        }
        throw DownloadFailure("The playlist only points at other playlists.")
    }

    private func fetchSegment(_ segment: HLS.MediaSegment) async throws -> Data {
        let data = try await fetch(segment.uri)
        guard let key = segment.key, key.method == "AES-128" else { return data }
        guard let keyURL = key.uri else { throw DownloadFailure("An encrypted segment names no key.") }
        let keyData = try await self.key(at: keyURL)
        let iv = key.iv ?? Self.sequenceIV(segment.sequence)
        return try Self.decrypt(data, key: keyData, iv: iv)
    }

    private func key(at url: URL) async throws -> Data {
        if let cached = keys[url] { return cached }
        let data = try await fetch(url)
        guard data.count == 16 else { throw DownloadFailure("The stream's key is not 16 bytes.") }
        keys[url] = data
        return data
    }

    private func fetch(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            for (key, value) in context.allHeaders { request.setValue(value, forHTTPHeaderField: key) }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw DownloadFailure("Not an HTTP response.") }
                switch http.statusCode {
                case 200...299: return data
                case 408, 425, 429, 500...599: throw RetryableError(http.statusCode)
                default: throw DownloadFailure("The server answered \(http.statusCode) for \(url.lastPathComponent).")
                }
            } catch let error as DownloadFailure {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < retryDelays.count else { throw DownloadFailure("Gave up on \(url.lastPathComponent): \(error.localizedDescription)") }
                try await Task.sleep(for: .seconds(retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    private struct RetryableError: Error {
        let status: Int
        init(_ status: Int) { self.status = status }
    }

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        let capacity = data.count + 16
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress, inPtr.baseAddress, data.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DownloadFailure("A segment could not be decrypted.") }
        return out.prefix(moved)
    }
}
