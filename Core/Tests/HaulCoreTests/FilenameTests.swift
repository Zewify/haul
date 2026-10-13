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
}
