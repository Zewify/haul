import Foundation
import Testing
@testable import HaulCore

/// Builds MP4 boxes by hand, for the shapes a real fixture cannot easily take.
enum Boxes {
    static func box(_ type: String, _ body: Data) -> Data {
        var data = Data()
        data.append(be32(UInt32(8 + body.count)))
        data.append(Data(type.utf8))
        data.append(body)
        return data
    }
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
    static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 255)]) }

    /// mvhd version 0: flags, two times, timescale, duration, then padding up to its usual size.
    static func mvhd(timescale: UInt32, duration: UInt32) -> Data {
        box("mvhd", Data([0, 0, 0, 0]) + be32(0) + be32(0) + be32(timescale) + be32(duration) + Data(count: 80))
    }
    static func trak(_ handler: String, width: UInt16 = 0, height: UInt16 = 0) -> Data {
        let tkhd = box("tkhd", Data([0, 0, 0, 0]) + Data(count: 72) + be32(UInt32(width) << 16) + be32(UInt32(height) << 16))
        let hdlr = box("hdlr", Data([0, 0, 0, 0]) + be32(0) + Data(handler.utf8) + Data(count: 12))
        return box("trak", tkhd + box("mdia", hdlr))
    }
    static func sidx(timescale: UInt32, durations: [UInt32]) -> Data {
        var body = Data([0, 0, 0, 0]) + be32(1) + be32(timescale) + be32(0) + be32(0) + be16(0) + be16(UInt16(durations.count))
        for d in durations { body += be32(1000) + be32(d) + be32(0x9000_0000) }
        return box("sidx", body)
    }
}

struct MP4ProbeTests {
    @Test func aVideoOnlyAndAnAudioOnlyFileAreToldApart() throws {
        let video = Boxes.box("ftyp", Data("isom".utf8)) + Boxes.box("moov", Boxes.mvhd(timescale: 1000, duration: 6000) + Boxes.trak("vide", width: 720, height: 1280))
        let audio = Boxes.box("moov", Boxes.mvhd(timescale: 44100, duration: 264_600) + Boxes.trak("soun"))
        let v = try #require(MP4Probe.read(video))
        #expect(v.duration == 6 && v.hasVideo && !v.hasAudio && v.width == 720 && v.height == 1280)
        let a = try #require(MP4Probe.read(audio))
        #expect(a.duration == 6 && !a.hasVideo && a.hasAudio)
    }

    /// Instagram's and Facebook's tracks: fragmented, mvhd says 0, the length is in the sidx after the moov.
    @Test func aFragmentedFileIsTimedByItsSegmentIndex() throws {
        let file = Boxes.box("moov", Boxes.mvhd(timescale: 1000, duration: 0) + Boxes.trak("vide", width: 640, height: 360))
            + Boxes.sidx(timescale: 15360, durations: [76800, 76800, 30720]) + Boxes.box("moof", Data(count: 16))
        #expect(try #require(MP4Probe.read(file)).duration == 12)
    }

    /// A long video's moov runs past the head Haul reads: a track past the cut must not read as missing.
    @Test func aCutShortMoovIsNotReadAsSilent() {
        let moov = Boxes.box("moov", Boxes.mvhd(timescale: 1000, duration: 9000) + Boxes.trak("vide") + Boxes.box("free", Data(count: 4000)) + Boxes.trak("soun"))
        let head = moov.prefix(600)
        #expect(MP4Probe.read(head) == nil)
        #expect(MP4Probe.requiredLength(head) == moov.count)
        #expect(MP4Probe.read(moov)?.hasAudio == true)
    }

    @Test func notAnMP4() {
        #expect(MP4Probe.read(Data("<html>".utf8)) == nil)
        #expect(MP4Probe.requiredLength(Data()) == nil)
    }
}

struct MediaInspectorTests {
    let server: TestServer
    init() throws { server = try TestServer() }
    var fetcher: MediaFetcher { MediaFetcher(context: RequestContext(), session: .shared, retryDelays: []) }

    @Test func aFileIsReadFromItsHeadOnly() async throws {
        let file = Boxes.box("moov", Boxes.mvhd(timescale: 1000, duration: 6000) + Boxes.trak("vide", width: 720, height: 1280)) + Boxes.box("mdat", TestServer.blob(2_000_000))
        server["/v.mp4"] = .init(data: file, contentType: "video/mp4")
        let found = await MediaInspector.inspect(server.url("/v.mp4"), kind: "file", fetcher: fetcher)
        #expect(found.duration == 6 && found.video == true && found.audio == false && found.width == 720)
        #expect(server.rangesRequested == ["bytes=0-\(MP4Probe.headLength - 1)"])
    }

    @Test func aServerThatIgnoresRangesIsNotReadToTheEnd() async throws {
        server.supportsRanges = false
        server.chunkDelayMs = 20
        let file = Boxes.box("moov", Boxes.mvhd(timescale: 1000, duration: 6000) + Boxes.trak("soun")) + Boxes.box("mdat", TestServer.blob(8_000_000))
        server["/a.mp4"] = .init(data: file)
        let started = Date()
        let found = await MediaInspector.inspect(server.url("/a.mp4"), kind: "file", fetcher: fetcher)
        #expect(found.audio == true)
        // Eight megabytes at 64 KiB per 20 ms would take two and a half seconds.
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    /// Dailymotion's player spends a one-time playlist link; the same link refuses anyone after it.
    @Test func aLinkHaulCannotFetchIsSaidToBe() async throws {
        server["/once.m3u8"] = .init(data: Data("used".utf8), status: 403)
        server["/gone.mp4"] = .init(data: Data(), status: 410)
        let stream = await MediaInspector.inspect(server.url("/once.m3u8"), kind: "hls", fetcher: fetcher)
        #expect(stream.error?.contains("403") == true && stream.duration == nil)
        let file = await MediaInspector.inspect(server.url("/gone.mp4"), kind: "file", fetcher: fetcher)
        #expect(file.error?.contains("410") == true)
    }

    @Test func aStreamIsTimedByItsSegmentsAndALiveOneIsSaidToBe() async throws {
        server["/vod.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:2.5,\nb.ts\n#EXT-X-ENDLIST\n".utf8))
        server["/live.m3u8"] = .init(data: Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:900\n#EXTINF:4,\nx.ts\n".utf8))
        let vod = await MediaInspector.inspect(server.url("/vod.m3u8"), kind: "hls", fetcher: fetcher)
        #expect(vod.duration == 6.5 && vod.live == nil)
        let live = await MediaInspector.inspect(server.url("/live.m3u8"), kind: "hls", fetcher: fetcher)
        #expect(live.live == true && live.duration == nil)
    }

    @Test func aLivePlaylistIsRefusedInPlainWordsAndAVODOneIsNot() async throws {
        server["/live.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\nx.ts\n".utf8))
        server["/vod.m3u8"] = .init(data: Data("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:4,\nx.ts\n".utf8))
        await #expect(throws: StreamSource.liveStream) { try await StreamSource.plan(.hls, url: server.url("/live.m3u8"), fetcher: fetcher) }
        #expect(try await StreamSource.plan(.hls, url: server.url("/vod.m3u8"), fetcher: fetcher).video.segments.count == 1)
    }
}
