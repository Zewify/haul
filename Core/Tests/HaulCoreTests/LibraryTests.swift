import Foundation
import Testing
@testable import HaulCore

struct LibraryTests {
    func temporaryStore() -> LibraryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("haul-tests-\(UUID().uuidString)")
        return LibraryStore(url: dir.appendingPathComponent("library.json"))
    }

    @Test func missingFileGivesDefaultsWithAFreshToken() {
        let a = temporaryStore().load()
        let b = temporaryStore().load()
        #expect(a.downloads.isEmpty)
        #expect(a.settings.askBeforeStarting)
        #expect(a.settings.connections == 4)
        #expect(a.settings.concurrent == 2)
        #expect(a.settings.port == 48512)
        #expect(a.settings.pairingToken.count >= 32)
        #expect(a.settings.pairingToken != b.settings.pairingToken)
    }

    @Test func roundTrip() throws {
        let store = temporaryStore()
        var library = store.load()
        var download = Download(url: URL(string: "https://example.com/a.zip")!, name: "a.zip", folder: URL(fileURLWithPath: "/tmp"), added: Date(timeIntervalSince1970: 1_000_000))
        download.size = 1000
        download.segments = [Segment(start: 0, end: 499, written: 100), Segment(start: 500, end: 999, written: 0)]
        download.state = .paused
        download.context = RequestContext(referrer: "https://example.com/", cookies: "a=b", userAgent: "UA", headers: ["X-Test": "1"])
        library.downloads.append(download)
        library.settings.pairedClients.append(PairedClient(client: "chrome", name: "Chrome", paired: Date()))
        try store.save(library)
        let loaded = store.load()
        #expect(loaded.downloads == [download])
        #expect(loaded.downloads[0].bytesReceived == 100)
        #expect(loaded.downloads[0].fraction == 0.1)
        #expect(loaded.settings.pairedClients.count == 1)
        #expect(loaded.settings.pairingToken == library.settings.pairingToken)
    }

    @Test func olderFileMissingKeysStillDecodes() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"downloads":[],"settings":{"pairingToken":"abc"}}"#.utf8).write(to: store.url)
        let loaded = store.load()
        #expect(loaded.settings.pairingToken == "abc")
        #expect(loaded.settings.connections == 4)
    }

    @Test func corruptFileGivesDefaultsWithoutCrashing() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load().downloads.isEmpty)
    }

    @Test func segmentArithmetic() {
        let segment = Segment(start: 10, end: 19, written: 4)
        #expect(segment.length == 10)
        #expect(segment.remaining == 6)
        #expect(!segment.isComplete)
        #expect(Segment(start: 0, end: 0, written: 1).isComplete)
    }

    @Test func failedStateCarriesItsMessage() throws {
        let state = DownloadState.failed("Disk full")
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(DownloadState.self, from: data) == state)
        #expect(state.isActive == false)
        #expect(DownloadState.downloading.isActive)
        #expect(DownloadState.queued.isActive)
    }
}
