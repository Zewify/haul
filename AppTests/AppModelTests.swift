import KomizoCore
import XCTest
@testable import Komizo

@MainActor
final class AppModelTests: XCTestCase {
    // Set up in the nonisolated setUpWithError, before any test touches them.
    nonisolated(unsafe) var folder: URL!
    nonisolated(unsafe) var store: LibraryStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("komizo-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        var library = Library()
        library.settings.downloadFolderPath = folder.path
        try store.save(library)
    }

    func testSettingsAreClampedToTheEngineLimits() throws {
        var library = store.load()
        library.settings.connections = 99
        library.settings.concurrent = 50
        try store.save(library)
        let model = AppModel(store: store)
        XCTAssertEqual(model.settings.connections, 32)
        XCTAssertEqual(model.settings.concurrent, 8)
        model.setConnections(10)
        XCTAssertEqual(model.engine.connections, 10)
    }

    func testPairingRecordsTheBrowserWhenApproved() async throws {
        let model = AppModel(store: store)
        model.pairingApprover = { _ in true }
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0"), delegate: model)
        let approved = await model.server(server, approvePairing: PairRequest(client: "chrome", name: "Chrome"))
        XCTAssertTrue(approved)
        XCTAssertEqual(model.settings.pairedClients.map(\.name), ["Chrome"])
        model.pairingApprover = { _ in false }
        let denied = await model.server(server, approvePairing: PairRequest(client: "safari", name: "Safari"))
        XCTAssertFalse(denied)
        XCTAssertEqual(model.settings.pairedClients.count, 1)
    }

    func testAnUnreachableFileIsRefusedSoTheBrowserKeepsItsOwnDownload() async throws {
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0"), delegate: model)
        let incoming = IncomingDownload(url: "http://127.0.0.1:1/nothing.zip", filename: "nothing.zip")
        do {
            _ = try await model.server(server, receive: incoming, media: false)
            XCTFail("expected a refusal")
        } catch ServerError.badRequest {
            // The extension then leaves the browser's download alone.
        }
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.engine.downloads.isEmpty)
    }

    func testAStreamWaitsInThePanelWhenAskingIsOn() async throws {
        let site = try TestServer()
        site["/y.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n".utf8), contentType: "application/vnd.apple.mpegurl")
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0"), delegate: model)
        let shown = expectation(description: "panel asked")
        model.onPending = { shown.fulfill() }
        _ = try await model.server(server, receive: IncomingDownload(url: site.url("/y.m3u8").absoluteString, kind: "hls", pageTitle: "A Clip"), media: true)
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertEqual(model.pending.first?.name, "A Clip")
        model.dismissCatch(model.pending.first!)
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testAProtectedStreamIsRefusedInPlainWords() async throws {
        let site = try TestServer()
        let mpd = #"<MPD type="static" mediaPresentationDuration="PT5S"><Period><AdaptationSet mimeType="video/mp4"><ContentProtection value="cenc"/><Representation id="v" codecs="avc1.64001f" bandwidth="1"/></AdaptationSet></Period></MPD>"#
        site["/m.mpd"] = .init(data: Data(mpd.utf8), contentType: "application/dash+xml")
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0"), delegate: model)
        do {
            _ = try await model.server(server, receive: IncomingDownload(url: site.url("/m.mpd").absoluteString, kind: "mpd", pageTitle: "Locked"), media: true)
            XCTFail("expected a refusal")
        } catch ServerError.badRequest(let message) {
            XCTAssertEqual(message, "This video is protected (DRM) and cannot be saved.")
        }
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testTheSpeedLimitReachesTheEngineAndSurvivesARelaunch() throws {
        let model = AppModel(store: store)
        XCTAssertNil(model.engine.limiter.bytesPerSecond)
        model.setSpeedLimit(3_000_000)
        XCTAssertNil(model.engine.limiter.bytesPerSecond, "a cap set while the limit is off waits for the switch")
        model.setLimitSpeed(true)
        XCTAssertEqual(model.engine.limiter.bytesPerSecond, 3_000_000)
        model.setSpeedLimit(10)
        XCTAssertEqual(model.engine.limiter.bytesPerSecond, SpeedLimiter.minimum)
        model.flush()
        XCTAssertEqual(AppModel(store: store).engine.limiter.bytesPerSecond, SpeedLimiter.minimum)
        model.setLimitSpeed(false)
        XCTAssertNil(model.engine.limiter.bytesPerSecond)
    }

    /// A DASH site that serves each track as one file goes through the segmented file engine, as Facebook's tracks do.
    func testADASHManifestOfWholeFilesBecomesAJoinedDownload() async throws {
        let site = try TestServer()
        let mpd = #"<MPD type="static" mediaPresentationDuration="PT5S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" codecs="avc1.64001f" height="720" bandwidth="2"><BaseURL>v.mp4</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation id="a" codecs="mp4a.40.2" bandwidth="1"><BaseURL>a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"#
        site["/m.mpd"] = .init(data: Data(mpd.utf8), contentType: "application/dash+xml")
        site["/v.mp4"] = .init(data: Data(count: 100), contentType: "video/mp4")
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0"), delegate: model)
        let shown = expectation(description: "panel asked")
        model.onPending = { shown.fulfill() }
        _ = try await model.server(server, receive: IncomingDownload(url: site.url("/m.mpd").absoluteString, kind: "mpd", pageTitle: "Whole"), media: true)
        await fulfillment(of: [shown], timeout: 5)
        let pending = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(pending.kind, .dash)
        XCTAssertEqual(pending.incoming.url, site.url("/v.mp4").absoluteString)
        XCTAssertEqual(pending.incoming.audioUrl, site.url("/a.m4a").absoluteString)
        XCTAssertEqual(pending.name, "Whole.mp4")
    }

    func testACatchToAChosenFolderCarriesABookmark() throws {
        let model = AppModel(store: store)
        let chosen = folder.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let pending = PendingCatch(incoming: IncomingDownload(url: "https://x/a.zip"), media: false, name: "a.zip", folder: chosen)
        model.startCatch(pending)
        let download = try XCTUnwrap(model.engine.downloads.first)
        XCTAssertNotNil(download.folderBookmark)
        XCTAssertEqual(download.folder.standardizedFileURL, chosen.standardizedFileURL)
        let other = PendingCatch(incoming: IncomingDownload(url: "https://x/b.zip"), media: false, name: "b.zip", folder: model.folder)
        model.startCatch(other)
        XCTAssertNil(model.engine.downloads.last?.folderBookmark, "the global folder has the app's own bookmark")
    }

    func testFlushWritesTheLibrary() throws {
        let model = AppModel(store: store)
        model.setAskBeforeStarting(false)
        model.flush()
        XCTAssertFalse(store.load().settings.askBeforeStarting)
    }
}
