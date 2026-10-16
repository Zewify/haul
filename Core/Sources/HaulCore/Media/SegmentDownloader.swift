import CommonCrypto
import Foundation

/// Saves one track of a stream as one file: its segments fetched a few at a time and appended in order, after its
/// init segment, AES-128 segments decrypted. HLS and DASH both resolve to a `StreamTrack` first (`StreamSource`).
public actor SegmentDownloader {
    private let track: StreamTrack
    private let fetcher: MediaFetcher
    private let partFile: PartFile
    private let parallel: Int
    /// Segments done, segments in all, and the byte offset the file is complete up to.
    private let onProgress: @Sendable (Int, Int, Int64) -> Void
    private var keys: [URL: Data] = [:]

    public init(track: StreamTrack, fetcher: MediaFetcher, partFile: PartFile, parallel: Int = 4,
                onProgress: @escaping @Sendable (Int, Int, Int64) -> Void) {
        self.track = track
        self.fetcher = fetcher
        self.partFile = partFile
        self.parallel = max(1, parallel)
        self.onProgress = onProgress
    }

    /// `skipping` segments already in the part file lets a paused download carry on; `resumeOffset` is the byte
    /// those segments end at, and anything past it (a segment half written when the app died) is cut off.
    public func run(skipping: Int = 0, resumeOffset: Int64 = 0) async throws {
        let segments = track.segments, map = track.map
        let handle: FileHandle
        do {
            handle = try partFile.writer()
        } catch {
            throw DownloadFailure("Cannot open the file: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var done = 0
        let total = segments.count
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
            let initData = try await fetcher.data(map.uri, range: map.range)
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
    }

    private func fetchSegment(_ segment: StreamSegment) async throws -> Data {
        let data = try await fetcher.data(segment.uri, range: segment.range)
        guard let key = segment.key, key.method == "AES-128" else { return data }
        guard let keyURL = key.uri else { throw DownloadFailure("An encrypted segment names no key.") }
        let keyData = try await self.key(at: keyURL)
        let iv = key.iv ?? Self.sequenceIV(segment.sequence)
        return try Self.decrypt(data, key: keyData, iv: iv)
    }

    private func key(at url: URL) async throws -> Data {
        if let cached = keys[url] { return cached }
        let data = try await fetcher.data(url)
        guard data.count == 16 else { throw DownloadFailure("The stream's key is not 16 bytes.") }
        keys[url] = data
        return data
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
