import Foundation
import Testing
@testable import KomizoCore

struct FacebookPageTests {
    func efg(_ videoId: String, _ duration: Int) -> String {
        Base64URL.encode(Data("{\"vencode_tag\":\"dash\",\"video_id\":\(videoId),\"duration_s\":\(duration)}".utf8))
    }

    func rep(_ id: String, _ mime: String, _ codecs: String, _ w: Int, _ h: Int, _ bw: Int, _ videoId: String) -> String {
        let mimeEscaped = mime.replacingOccurrences(of: "/", with: "\\/")
        return "{\"representation_id\":\"\(id)\",\"mime_type\":\"\(mimeEscaped)\",\"codecs\":\"\(codecs)\",\"base_url\":\"https:\\/\\/video.xx.fbcdn.net\\/v\\/\(id).mp4?efg=\(efg(videoId, 90))\\u00253D&oh=1\",\"bandwidth\":\(bw),\"height\":\(h),\"width\":\(w),\"segments\":[{\"start\":0,\"end\":1}]}"
    }

    @Test func pairsTheBestVideoAndAudioPerVideoWithH264First() throws {
        let sets = "[{\"initial_representation_ids\":[],\"representations\":[" + [
            rep("a1", "video/mp4", "av01.0.08M.08", 1080, 1080, 900_000, "111"),
            rep("a2", "video/mp4", "avc1.64001F", 720, 720, 800_000, "111"),
            rep("a4", "audio/mp4", "mp4a.40.5", 0, 0, 48_000, "111"),
            rep("a5", "audio/mp4", "mp4a.40.2", 0, 0, 128_000, "111"),
            rep("c1", "video/mp4", "vp09.00.40.08", 1920, 1920, 900_000, "111"),
        ].joined(separator: ",") + "]}]"
        let html = "<html><script>{\"x\":1,\"all_video_dash_prefetch_representations\":\(sets),\"y\":2}</script><title>Facebook</title></html>"
        let pairs = FacebookPage.dashPairs(in: html)
        #expect(pairs.count == 2)
        #expect(pairs[0].videoId == "111")
        #expect(pairs[0].codec == "H.264")
        #expect(pairs[0].height == 720)
        #expect(pairs[0].videoURL.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/a2.mp4?efg="))
        #expect(pairs[0].audioURL.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/a5.mp4?efg="))
        #expect(pairs[0].duration == 90)
        #expect(pairs[1].codec == "AV1")
        #expect(pairs[1].height == 1080)
        #expect(FacebookPage.dashPairs(in: "<html>nothing</html>").isEmpty)
    }

    @Test func picksThePageVideoByURLIdThenTheFirst() throws {
        let sets = "[{\"initial_representation_ids\":[],\"representations\":[" + [
            rep("x1", "video/mp4", "avc1.64001F", 720, 720, 800_000, "26934216426212982"),
            rep("x2", "audio/mp4", "mp4a.40.2", 0, 0, 128_000, "26934216426212982"),
            rep("y1", "video/mp4", "avc1.64001F", 480, 480, 500_000, "222"),
            rep("y2", "audio/mp4", "mp4a.40.2", 0, 0, 96_000, "222"),
        ].joined(separator: ",") + "]}]"
        let html = "<script>\"all_video_dash_prefetch_representations\":\(sets)</script>"
        let pairs = FacebookPage.dashPairs(in: html)
        let chosen = try #require(FacebookPage.pair(for: URL(string: "https://www.facebook.com/reel/26934216426212982")!, among: pairs))
        #expect(chosen.videoId == "26934216426212982")
        let fallback = try #require(FacebookPage.pair(for: URL(string: "https://www.facebook.com/share/r/abc/")!, among: pairs))
        #expect(fallback.videoId == pairs[0].videoId)
        #expect(FacebookPage.pair(for: URL(string: "https://www.facebook.com/reel/999")!, among: pairs) == nil, "an id the page does not have is not another video")
        #expect(FacebookPage.videoId(in: URL(string: "https://www.facebook.com/watch/?v=123")!) == "123")
        #expect(FacebookPage.isFacebook(URL(string: "https://m.facebook.com/reel/1")!))
        #expect(!FacebookPage.isFacebook(URL(string: "https://example.com/reel/1")!))
    }

    func nativeBlock(_ id: String, _ dur: Int, hdTag: String = "xpv_progressive.FACEBOOK..C3.720.dash_h264-basic-gen2_720p") -> String {
        let hdEfg = Base64URL.encode(Data("{\"vencode_tag\":\"\(hdTag)\",\"duration_s\":\(dur)}".utf8))
        let sdEfg = Base64URL.encode(Data("{\"vencode_tag\":\"xpv_progressive.FACEBOOK..C3.360.sve_sd\",\"duration_s\":\(dur)}".utf8))
        return "{\"dash_manifest_url\":\"https:\\/\\/www.facebook.com\\/dash_mpd_debug.mpd?v=\(id)&dummy=.mpd\",\"browser_native_sd_url\":\"https:\\/\\/video.xx.fbcdn.net\\/v\\/sd-\(id).mp4?efg=\(sdEfg)\\u00253D\",\"browser_native_hd_url\":\"https:\\/\\/video.xx.fbcdn.net\\/v\\/hd-\(id).mp4?efg=\(hdEfg)\\u00253D\"}"
    }

    @Test func nativePairsFollowTheirManifestId() throws {
        let html = "<html>" + nativeBlock("1619008336628300", 3315) + "<p>x</p>" + nativeBlock("1555707113014861", 11) + "</html>"
        let pairs = FacebookPage.nativePairs(in: html)
        #expect(pairs.map(\.videoId) == ["1619008336628300", "1555707113014861"])
        #expect(pairs[0].hdURL?.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/hd-1619008336628300.mp4") == true)
        #expect(pairs[0].sdURL?.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/sd-1619008336628300.mp4") == true)
        #expect(pairs[0].duration == 3315)
        #expect(pairs[0].hdIsH264)
    }

    @Test func aLinkWithAnIdNeverFallsBackToAnotherVideo() throws {
        let html = "<html>" + nativeBlock("1555707113014861", 11) + "</html>"
        #expect(FacebookPage.download(for: URL(string: "https://www.facebook.com/reel/1619008336628300")!, html: html, folder: URL(fileURLWithPath: "/tmp/x")) == nil)
        let share = try #require(FacebookPage.download(for: URL(string: "https://www.facebook.com/share/r/abc/")!, html: html, folder: URL(fileURLWithPath: "/tmp/x")))
        #expect(share.name == "Facebook 1555707113014861.mp4", "a share link names no video, so the page's first one is it")
    }

    @Test func aNativeH264FileBeatsTheDashTableForAPastedLink() throws {
        let sets = "[{\"initial_representation_ids\":[],\"representations\":[" + [
            rep("v1", "video/mp4", "vp09.00.40.08", 1080, 1080, 900_000, "1619008336628300"),
            rep("a1", "audio/mp4", "mp4a.40.5", 0, 0, 48_000, "1619008336628300"),
        ].joined(separator: ",") + "]}]"
        let html = "<html><title>Facebook</title>" + nativeBlock("1619008336628300", 3315) + "<script>\"all_video_dash_prefetch_representations\":\(sets)</script></html>"
        let folder = URL(fileURLWithPath: "/tmp/x")
        let download = try #require(FacebookPage.download(for: URL(string: "https://www.facebook.com/reel/1619008336628300")!, html: html, folder: folder))
        #expect(download.kind == .dash)
        #expect(download.url.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/hd-1619008336628300.mp4"), "the H.264 progressive file, not the VP9 table")
        #expect(download.audioURL?.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/sd-1619008336628300.mp4") == true, "the SD file lends its sound if the HD one is silent")
        #expect(download.name == "Facebook 1619008336628300.mp4")
    }

    @Test func aPastedReelLinkBecomesAJoinedDownload() throws {
        let sets = "[{\"initial_representation_ids\":[],\"representations\":[" + [
            rep("x1", "video/mp4", "avc1.64001F", 720, 720, 800_000, "26934216426212982"),
            rep("x2", "audio/mp4", "mp4a.40.2", 0, 0, 128_000, "26934216426212982"),
        ].joined(separator: ",") + "]}]"
        let html = "<html><head><title>Facebook</title></head><script>\"all_video_dash_prefetch_representations\":\(sets)</script></html>"
        let folder = URL(fileURLWithPath: "/tmp/x")
        let download = try #require(FacebookPage.download(for: URL(string: "https://www.facebook.com/reel/26934216426212982")!, html: html, folder: folder))
        #expect(download.kind == .dash)
        #expect(download.name == "Facebook 26934216426212982.mp4")
        #expect(download.url.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/x1.mp4"))
        #expect(download.audioURL?.absoluteString.hasPrefix("https://video.xx.fbcdn.net/v/x2.mp4") == true)
        #expect(download.media)
        #expect(download.context.referrer == "https://www.facebook.com/reel/26934216426212982")
        #expect(FacebookPage.download(for: URL(string: "https://www.facebook.com/reel/1")!, html: "<html>login</html>", folder: folder) == nil)
    }
}
