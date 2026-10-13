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
        guard case .master(let variants) = try HLS.parse(text, base: base) else { Issue.record("not master"); return }
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
        #expect(map == URL(string: "https://cdn.example/v/init.mp4"))
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

    @Test func notAPlaylistThrows() {
        #expect(throws: HLS.ParseError.notAPlaylist) { try HLS.parse("<html>", base: base) }
    }
}

struct HLSDownloaderTests {
    let server: TestServer
    let folder: URL
    let key = Data((0..<16).map { UInt8($0 * 7) })
    let iv = Data((0..<16).map { UInt8(255 - $0) })

    init() throws {
        server = try TestServer()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-hls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        let downloader = HLSDownloader(url: server.url("/master.m3u8"), context: RequestContext(), session: .shared, partFile: part, parallel: 2) { done, total in
            counter.record(done, total)
        }
        let ext = try await downloader.run()
        #expect(ext == "ts")
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
        let downloader = HLSDownloader(url: server.url("/media.m3u8"), context: RequestContext(), session: .shared, partFile: part) { _, _ in }
        #expect(try await downloader.run() == "mp4")
        #expect(try Data(contentsOf: part.url) == initData + a + b)
    }

    @Test func missingSegmentFails() async throws {
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\nmissing.ts\n#EXT-X-ENDLIST\n".utf8))
        let part = PartFile(folder: folder, name: "x.ts")
        try part.prepare(size: nil)
        let downloader = HLSDownloader(url: server.url("/media.m3u8"), context: RequestContext(), session: .shared, partFile: part, retryDelays: [0.01]) { _, _ in }
        await #expect(throws: DownloadFailure.self) { try await downloader.run() }
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: (Int, Int) = (0, 0)
    func record(_ done: Int, _ total: Int) { lock.withLock { _last = (done, total) } }
    var last: (Int, Int) { lock.withLock { _last } }
}
