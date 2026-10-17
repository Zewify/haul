import Foundation
import Testing
@testable import HaulCore

struct FilenameTests {
    @Test func contentDispositionForms() {
        #expect(Filename.fromContentDisposition(#"attachment; filename="report final.pdf""#) == "report final.pdf")
        #expect(Filename.fromContentDisposition("attachment; filename=plain.zip") == "plain.zip")
        #expect(Filename.fromContentDisposition("attachment; filename*=UTF-8''caf%C3%A9%20menu.pdf") == "café menu.pdf")
        #expect(Filename.fromContentDisposition(#"attachment; filename="old.txt"; filename*=UTF-8''new.txt"#) == "new.txt")
        #expect(Filename.fromContentDisposition("inline") == nil)
        #expect(Filename.fromContentDisposition("attachment; filename=\"\"") == nil)
    }

    @Test func fromURLUsesTheLastPathComponentDecoded() {
        #expect(Filename.fromURL(URL(string: "https://x.com/dl/My%20File.dmg?token=1#frag")!) == "My File.dmg")
        #expect(Filename.fromURL(URL(string: "https://x.com/")!) == "download")
        #expect(Filename.fromURL(URL(string: "https://x.com")!) == "download")
    }

    @Test func filenameIsSanitised() {
        #expect(Filename.sanitised("../../etc/passwd") == "passwd")
        #expect(Filename.sanitised("..\\..\\win.ini") == "win.ini")
        #expect(Filename.sanitised(".hidden") == "hidden")
        #expect(Filename.sanitised("a\u{0}b\nc.txt") == "abc.txt")
        #expect(Filename.sanitised("a:b/c.txt") == "c.txt")
        #expect(Filename.sanitised("a:b.txt") == "a_b.txt")
        #expect(Filename.sanitised("trailing/") == "trailing")
        #expect(Filename.sanitised("   ") == "download")
        #expect(Filename.sanitised("...") == "download")
        let long = String(repeating: "é", count: 200) + ".bin"
        let trimmed = Filename.sanitised(long)
        #expect(trimmed.utf8.count <= 255)
        #expect(trimmed.hasSuffix(".bin"))
    }

    @Test func collisionsAreNumbered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Filename.available("a.zip", in: folder) == "a.zip")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.zip").path, contents: Data())
        #expect(Filename.available("a.zip", in: folder) == "a 2.zip")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a 2.zip").path, contents: Data())
        #expect(Filename.available("a.zip", in: folder) == "a 3.zip")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("noext").path, contents: Data())
        #expect(Filename.available("noext", in: folder) == "noext 2")
        // A part file in progress counts as taken too, so two downloads of the same name never share one.
        FileManager.default.createFile(atPath: folder.appendingPathComponent("b.zip.haulpart").path, contents: Data())
        #expect(Filename.available("b.zip", in: folder) == "b 2.zip")
    }
}

struct MediaNameTests {
    @Test func mediaIsNamedAfterThePageWhenTheURLIsAHash() {
        let hash = URL(string: "https://video.xx.fbcdn.net/o1/v/t2/f2/m366/AQNT_ORrNM_72Ua5LDXwPUD13LZGcIJrDVl.mp4?efg=1")!
        #expect(Filename.mediaName(pageTitle: "Sunset over Manila | Facebook", url: hash, contentType: "video/mp4") == "Sunset over Manila - Facebook.mp4")
        #expect(Filename.mediaName(pageTitle: "Facebook", url: hash, contentType: "video/mp4") == "Facebook.mp4")
        #expect(Filename.mediaName(pageTitle: nil, url: hash, contentType: "video/mp4") == "AQNT_ORrNM_72Ua5LDXwPUD13LZGcIJrDVl.mp4")
        #expect(Filename.mediaName(pageTitle: "  ", url: URL(string: "https://c.com/v/clip")!, contentType: "video/webm") == "clip.webm")
        #expect(Filename.mediaName(pageTitle: "A Clip", url: URL(string: "https://c.com/v/master.m3u8")!, contentType: nil) == "A Clip")
    }

    @Test func aBareSiteTitleGetsTheVideoId() {
        let hash = URL(string: "https://scontent.xx.fbcdn.net/v/AQNwtkB9F6JmSviz4edJ.mp4?efg=1")!
        #expect(Filename.mediaName(pageTitle: "Facebook", url: hash, contentType: "video/mp4", videoId: "26934216426212982") == "Facebook 26934216426212982.mp4")
        #expect(Filename.mediaName(pageTitle: "Sunset over Manila | Facebook", url: hash, contentType: "video/mp4", videoId: "1") == "Sunset over Manila - Facebook.mp4")
        #expect(Filename.mediaName(pageTitle: nil, url: hash, contentType: "video/mp4", videoId: "99") == "AQNwtkB9F6JmSviz4edJ.mp4")
    }
}

struct MediaTitleTests {
    let url = URL(string: "https://cdn.example/v/abc.mp4")!

    @Test func aSlashInATitleIsNotAFolder() {
        // Reddit titles end " : r/subreddit"; the slash once cut everything before it, leaving "CompetitivePUBG.mp4".
        #expect(Filename.mediaName(pageTitle: "Best apology in sports history : r/nextfuckinglevel", url: url, contentType: "video/mp4")
                == "Best apology in sports history - r-nextfuckinglevel.mp4")
    }

    @Test func aCaptionAsTitleKeepsItsFirstLineAndAReasonableLength() {
        // Instagram's og:title is the whole caption; it once ran a joined download's part name past 255 bytes.
        let caption = "NASA on Instagram: \"POV: you're watching the Earth set\nWe just released new footage from the far side of the Moon, captured by the crew on the way home, and it is \(String(repeating: "stunning ", count: 30))\""
        let name = Filename.mediaName(pageTitle: caption, url: url, contentType: "video/mp4")
        #expect(name.hasPrefix("NASA on Instagram_ \"POV_ you're watching the Earth set"))
        #expect(!name.contains("We just"))
        let long = Filename.mediaName(pageTitle: String(repeating: "朱棣我的侄子走丢了有好心人能帮帮我吗", count: 12), url: url, contentType: "video/mp4")
        #expect(long.utf8.count <= Filename.titleBytes + 4)
        #expect(long.hasSuffix("….mp4"))
        // What a two-track download writes next to it must still be a legal name.
        #expect((long + " (video).mp4.haulpart").utf8.count < 255)
    }
}
