import CommonCrypto
import Foundation
import Testing
@testable import HaulCore

struct HLSParserTests {
    let base = URL(string: "https://cdn.example/v/main.m3u8")!

    @Test func masterListsVariantsWithBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        https://other.example/hi.m3u8
        """
        guard case .master(let variants, _) = try HLS.parse(text, base: base) else { Issue.record("not master"); return }
        #expect(variants.count == 2)
        #expect(variants[0].uri == URL(string: "https://cdn.example/v/low/index.m3u8"))
        #expect(variants[0].bandwidth == 800_000)
        #expect(variants[0].resolution == "640x360")
        #expect(variants[1].uri == URL(string: "https://other.example/hi.m3u8"))
        #expect(HLS.best(of: variants)?.bandwidth == 2_500_000)
    }

    @Test func mediaPlaylistWithKeysAndMap() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:10
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:5.000,
        seg10.m4s
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:4.5,title
        seg11.m4s
        #EXTINF:6,
        seg12.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let segments, let map, let endList) = try HLS.parse(text, base: base) else { Issue.record("not media"); return }
        #expect(endList)
        #expect(map?.uri == URL(string: "https://cdn.example/v/init.mp4"))
        #expect(map?.range == nil)
        #expect(segments.count == 3)
        #expect(segments[0].sequence == 10)
        #expect(segments[0].key == nil)
        #expect(segments[0].duration == 5)
        #expect(segments[1].key?.method == "AES-128")
        #expect(segments[1].key?.uri == URL(string: "https://cdn.example/v/key.bin"))
        #expect(segments[1].key?.iv == Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]))
        #expect(segments[2].key?.method == "AES-128")
        #expect(segments[2].sequence == 12)
        #expect(segments[2].uri == URL(string: "https://cdn.example/v/seg12.m4s"))
    }

    @Test func sampleAESIsDRM() {
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n#EXTINF:4,\na.ts\n"
        #expect(throws: HLS.ParseError.drm) { try HLS.parse(text, base: base) }
    }

    @Test func masterWithSeparateAudioPicksTheGroupsDefaultRendition() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="low",DEFAULT=NO,AUTOSELECT=NO,URI="a-low.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="medium",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="a-med.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="aud",SUBTITLES="subs"
        v.m3u8
        """
        guard case .master(let variants, let audio) = try HLS.parse(text, base: base) else { Issue.record("not master"); return }
        #expect(audio.count == 2)
        #expect(variants[0].audioGroup == "aud")
        let chosen = try #require(HLS.audio(for: variants[0], in: audio))
        #expect(chosen.uri == URL(string: "https://cdn.example/v/a-med.m3u8"))
        #expect(chosen.language == "en")
    }

    @Test func audioRenditionWithoutAURIMeansTheSoundIsInTheVariant() throws {
        let text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"Main\",DEFAULT=YES\n#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"aac\"\nv.m3u8\n"
        guard case .master(let variants, let audio) = try HLS.parse(text, base: base) else { Issue.record("not master"); return }
        #expect(HLS.audio(for: variants[0], in: audio) == nil)
    }

    @Test func byteRangesFollowOnFromThePreviousOneInTheSameFile() throws {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="all.mp4",BYTERANGE="100@0"
        #EXTINF:4,
        #EXT-X-BYTERANGE:500@100
        all.mp4
        #EXTINF:4,
        #EXT-X-BYTERANGE:300
        all.mp4
        #EXTINF:4,
        #EXT-X-BYTERANGE:50
        other.mp4
        #EXT-X-ENDLIST
        """
        guard case .media(let segments, let map, _) = try HLS.parse(text, base: base) else { Issue.record("not media"); return }
        #expect(map?.range == 0...99)
        #expect(segments.map(\.range) == [100...599, 600...899, 0...49])
    }

    @Test func notAPlaylistThrows() {
        #expect(throws: HLS.ParseError.notAPlaylist) { try HLS.parse("<html>", base: base) }
    }
}

struct SegmentDownloaderTests {
    let server: TestServer
    let folder: URL
    let key = Data((0..<16).map { UInt8($0 * 7) })
    let iv = Data((0..<16).map { UInt8(255 - $0) })

    init() throws {
        server = try TestServer()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-hls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Resolves the playlist the way a download does, then saves its video track into `part`.
    func save(_ path: String, into part: PartFile, parallel: Int = 4, retryDelays: [TimeInterval] = DownloadTask.defaultRetryDelays,
              skipping: Int = 0, resumeOffset: Int64 = 0, onProgress: @escaping @Sendable (Int, Int, Int64) -> Void = { _, _, _ in }) async throws -> StreamTrack {
        let fetcher = MediaFetcher(context: RequestContext(), session: .shared, retryDelays: retryDelays)
        let plan = try await StreamSource.plan(.hls, url: server.url(path), fetcher: fetcher)
        let downloader = SegmentDownloader(track: plan.video, fetcher: fetcher, partFile: part, parallel: parallel, onProgress: onProgress)
        try await downloader.run(skipping: skipping, resumeOffset: resumeOffset)
        return plan.video
    }

    func encrypt(_ data: Data) -> Data {
        let capacity = data.count + 16
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, 16, ivPtr.baseAddress, inPtr.baseAddress, data.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        return out.prefix(moved)
    }

    @Test func concatenatesSegmentsInOrderAndDecrypts() async throws {
        let s1 = TestServer.blob(100_000, seed: 1), s2 = TestServer.blob(70_000, seed: 2), s3 = TestServer.blob(50_000, seed: 3)
        server["/s1.ts"] = .init(data: s1, contentType: "video/mp2t")
        server["/s2.ts"] = .init(data: encrypt(s2), contentType: "video/mp2t")
        server["/s3.ts"] = .init(data: encrypt(s3), contentType: "video/mp2t")
        server["/key.bin"] = .init(data: key)
        let ivHex = iv.map { String(format: "%02x", $0) }.joined()
        let media = """
        #EXTM3U
        #EXTINF:4,
        s1.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x\(ivHex)
        #EXTINF:4,
        s2.ts
        #EXTINF:4,
        s3.ts
        #EXT-X-ENDLIST
        """
        server["/media.m3u8"] = .init(data: Data(media.utf8), contentType: "application/vnd.apple.mpegurl")
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n"
        server["/master.m3u8"] = .init(data: Data(master.utf8), contentType: "application/vnd.apple.mpegurl")

        let part = PartFile(folder: folder, name: "video.ts")
        try part.prepare(size: nil)
        let counter = ProgressCounter()
        let track = try await save("/master.m3u8", into: part, parallel: 2) { done, total, _ in counter.record(done, total) }
        #expect(track.fileExtension == "ts")
        #expect(try Data(contentsOf: part.url) == s1 + s2 + s3)
        #expect(counter.last == (3, 3))
    }

    @Test func fragmentedMP4GetsItsInitSegmentFirst() async throws {
        let initData = Data("INIT".utf8), a = Data("AAAA".utf8), b = Data("BBBB".utf8)
        server["/init.mp4"] = .init(data: initData)
        server["/a.m4s"] = .init(data: a)
        server["/b.m4s"] = .init(data: b)
        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\na.m4s\n#EXTINF:4,\nb.m4s\n#EXT-X-ENDLIST\n"
        server["/media.m3u8"] = .init(data: Data(media.utf8))
        let part = PartFile(folder: folder, name: "video")
        try part.prepare(size: nil)
        #expect(try await save("/media.m3u8", into: part).fileExtension == "mp4")
        #expect(try Data(contentsOf: part.url) == initData + a + b)
    }

    @Test func resumeSkipsSavedSegmentsAndRestartsWhenTheCountChanged() async throws {
        let a = Data("AAAA".utf8), b = Data("BBBB".utf8)
        server["/a.ts"] = .init(data: a)
        server["/b.ts"] = .init(data: b)
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n".utf8))
        let part = PartFile(folder: folder, name: "r.ts")
        try part.prepare(size: nil)
        try part.write(a, at: 0)
        let offsets = ProgressCounter()
        _ = try await save("/media.m3u8", into: part, skipping: 1, resumeOffset: 4) { done, total, bytes in
            offsets.record(done, total); offsets.recordBytes(bytes)
        }
        #expect(try Data(contentsOf: part.url) == a + b)
        #expect(offsets.bytes == 8)
        #expect(server.requests.filter { $0.path == "/a.ts" }.isEmpty)
        // A skip past the end means the stream changed: start over, discarding what was there.
        try part.write(Data("JUNK".utf8), at: 8)
        _ = try await save("/media.m3u8", into: part, skipping: 5, resumeOffset: 12)
        #expect(try Data(contentsOf: part.url) == a + b)
    }

    @Test func resumeTruncatesAPartialSegmentLeftByACrash() async throws {
        let a = Data("AAAA".utf8), b = Data("BBBB".utf8)
        server["/a.ts"] = .init(data: a)
        server["/b.ts"] = .init(data: b)
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n".utf8))
        let part = PartFile(folder: folder, name: "crash.ts")
        try part.prepare(size: nil)
        try part.write(a + Data("BB".utf8), at: 0)   // the second segment was half written when the app died
        _ = try await save("/media.m3u8", into: part, skipping: 1, resumeOffset: 4)
        #expect(try Data(contentsOf: part.url) == a + b)
    }

    @Test func missingSegmentFails() async throws {
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\nmissing.ts\n#EXT-X-ENDLIST\n".utf8))
        let part = PartFile(folder: folder, name: "x.ts")
        try part.prepare(size: nil)
        await #expect(throws: DownloadFailure.self) { try await save("/media.m3u8", into: part, retryDelays: [0.01]) }
    }

    @Test func byteRangeSegmentsAreFetchedAsRanges() async throws {
        let file = TestServer.blob(1_000, seed: 9)
        server["/all.mp4"] = .init(data: file)
        let media = "#EXTM3U\n#EXT-X-MAP:URI=\"all.mp4\",BYTERANGE=\"100@0\"\n#EXTINF:4,\n#EXT-X-BYTERANGE:600@100\nall.mp4\n#EXTINF:4,\n#EXT-X-BYTERANGE:300\nall.mp4\n#EXT-X-ENDLIST\n"
        server["/media.m3u8"] = .init(data: Data(media.utf8))
        let part = PartFile(folder: folder, name: "ranged")
        try part.prepare(size: nil)
        _ = try await save("/media.m3u8", into: part)
        #expect(try Data(contentsOf: part.url) == file)
        #expect(Set(server.rangesRequested) == ["bytes=0-99", "bytes=100-699", "bytes=700-999"])
    }

    @Test func aServerThatIgnoresRangesStillYieldsJustTheRange() async throws {
        let file = TestServer.blob(1_000, seed: 4)
        server.supportsRanges = false
        server["/all.ts"] = .init(data: file)
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\n#EXT-X-BYTERANGE:200@300\nall.ts\n#EXT-X-ENDLIST\n".utf8))
        let part = PartFile(folder: folder, name: "ignored")
        try part.prepare(size: nil)
        _ = try await save("/media.m3u8", into: part)
        #expect(try Data(contentsOf: part.url) == file.subdata(in: 300..<500))
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: (Int, Int) = (0, 0)
    private var _bytes: Int64 = 0
    func record(_ done: Int, _ total: Int) { lock.withLock { _last = (done, total) } }
    func recordBytes(_ bytes: Int64) { lock.withLock { _bytes = bytes } }
    var last: (Int, Int) { lock.withLock { _last } }
    var bytes: Int64 { lock.withLock { _bytes } }
}
