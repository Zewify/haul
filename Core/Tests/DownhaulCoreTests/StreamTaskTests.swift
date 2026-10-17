import Foundation
import Testing
@testable import DownhaulCore

/// A stream whose sound comes separately (TED's HLS, any DASH site) is saved as two tracks and joined into one MP4.
@Suite(.enabled(if: avAvailable, "needs a media session"))
struct StreamTaskJoinTests {
    let server: TestServer
    let folder: URL
    let video: Data
    let audio: Data

    init() throws {
        server = try TestServer()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downhaul-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixtures = folder.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try Fixtures.videoOnly(at: fixtures.appendingPathComponent("v.mp4"))
        try Fixtures.audioOnly(at: fixtures.appendingPathComponent("a.mp4"))
        video = try Data(contentsOf: fixtures.appendingPathComponent("v.mp4"))
        audio = try Data(contentsOf: fixtures.appendingPathComponent("a.mp4"))
        try FileManager.default.removeItem(at: fixtures)
        server["/v.mp4"] = .init(data: video, contentType: "video/mp4")
        server["/a.mp4"] = .init(data: audio, contentType: "audio/mp4")
        // Each track is its file in two byte ranges, so the concatenated segments are the file again.
        server["/video.m3u8"] = .init(data: Data(Self.halves("v.mp4", video.count).utf8))
        server["/audio.m3u8"] = .init(data: Data(Self.halves("a.mp4", audio.count).utf8))
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="aud"
        video.m3u8
        """
        server["/master.m3u8"] = .init(data: Data(master.utf8))
    }

    static func halves(_ file: String, _ size: Int) -> String {
        let first = size / 2
        return "#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:\(first)@0\n\(file)\n#EXTINF:1,\n#EXT-X-BYTERANGE:\(size - first)\n\(file)\n#EXT-X-ENDLIST\n"
    }

    /// What the engine does at add: the name is claimed with an empty part file.
    func claimed(_ name: String) throws -> Download {
        var download = Download(url: server.url("/master.m3u8"), kind: .hls, name: name, folder: folder)
        let part = PartFile(folder: folder, name: name)
        try part.prepare(size: nil)
        download.partPath = part.url.path
        return download
    }

    @Test func separateAudioIsJoinedIntoOneMP4AndThePartsAreGone() async throws {
        let task = StreamTask(download: try claimed("Talk"), session: .shared, retryDelays: [0.01]) { _ in }
        let result = await task.run()
        #expect(result.state == .finished)
        #expect(result.finalPath == folder.appendingPathComponent("Talk.mp4").path)
        #expect(result.mediaDone == 4 && result.mediaTotal == 4)
        #expect(result.mediaTrack == nil)
        let info = try #require(await MediaInfo.inspect(folder.appendingPathComponent("Talk.mp4")))
        #expect(info.hasVideo && info.hasAudio)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Talk.mp4"])
    }

    @Test func aResumeOnTheAudioTrackKeepsTheVideoItAlreadyHas() async throws {
        var download = try claimed("Resumed")
        try download.trackParts.video.prepare(size: nil)
        try download.trackParts.video.write(video, at: 0)
        download.mediaTrack = 1
        download.mediaDone = 2
        download.mediaTotal = 4
        download.mediaOffset = 0
        let result = await StreamTask(download: download, session: .shared, retryDelays: [0.01]) { _ in }.run()
        #expect(result.state == .finished)
        #expect(server.requests.filter { $0.path == "/v.mp4" }.isEmpty)
        let path = try #require(result.finalPath)
        let info = try #require(await MediaInfo.inspect(URL(fileURLWithPath: path)))
        #expect(info.hasVideo && info.hasAudio)
    }
}

struct StreamTaskTests {
    let server: TestServer
    let folder: URL

    init() throws {
        server = try TestServer()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downhaul-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func aProtectedManifestFailsWithASentenceNotAJunkFile() async throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet mimeType="video/mp4">
          <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc"/>
          <Representation id="v" codecs="avc1.64001f" bandwidth="1"><BaseURL>v.mp4</BaseURL></Representation>
        </AdaptationSet></Period></MPD>
        """
        server["/manifest.mpd"] = .init(data: Data(mpd.utf8), contentType: "application/dash+xml")
        let download = Download(url: server.url("/manifest.mpd"), kind: .mpd, name: "Locked", folder: folder)
        let result = await StreamTask(download: download, session: .shared, retryDelays: [0.01]) { _ in }.run()
        #expect(result.state == .failed("This video is protected (DRM) and cannot be saved."))
        #expect(server.requests.filter { $0.path == "/v.mp4" }.isEmpty)
    }

    @Test func numberedDASHSegmentsBecomeOneFile() async throws {
        let mpd = """
        <MPD type="static" mediaPresentationDuration="PT3S"><Period><AdaptationSet mimeType="video/mp4" codecs="avc1.4d401f">
          <SegmentTemplate media="s$Number$.m4s" initialization="init.mp4" duration="1"/>
          <Representation id="v" bandwidth="1" height="360"/>
        </AdaptationSet></Period></MPD>
        """
        server["/manifest.mpd"] = .init(data: Data(mpd.utf8))
        server["/init.mp4"] = .init(data: Data("INIT".utf8))
        for n in 1...3 { server["/s\(n).m4s"] = .init(data: Data("S\(n)".utf8)) }
        let download = Download(url: server.url("/manifest.mpd"), kind: .mpd, name: "Clip", folder: folder)
        let result = await StreamTask(download: download, session: .shared, retryDelays: [0.01]) { _ in }.run()
        #expect(result.state == .finished)
        let path = try #require(result.finalPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("INITS1S2S3".utf8))
        #expect(result.finalPath?.hasSuffix("Clip.mp4") == true)
    }
}
