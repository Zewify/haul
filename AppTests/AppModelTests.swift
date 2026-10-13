import HaulCore
import XCTest
@testable import Haul

@MainActor
final class AppModelTests: XCTestCase {
    var folder: URL!
    var store: LibraryStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = LibraryStore(url: folder.appendingPathComponent("library.json"))
        var library = Library()
        library.settings.downloadFolderPath = folder.path
        try store.save(library)
    }

    func testFreeSettingsAreClampedByTheGate() throws {
        var library = store.load()
        library.settings.connections = 99
        library.settings.concurrent = 50
        try store.save(library)
        let model = AppModel(store: store)
        XCTAssertFalse(model.isPro)
        XCTAssertEqual(model.settings.connections, 4)
        XCTAssertEqual(model.settings.concurrent, 2)
        model.setConnections(10)
        XCTAssertEqual(model.engine.connections, 4)
    }

    func testPairingRecordsTheBrowserWhenApproved() async throws {
        let model = AppModel(store: store)
        model.pairingApprover = { _ in true }
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0", edition: .store, features: .init(media: false)), delegate: model)
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
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0", edition: .store, features: .init(media: false)), delegate: model)
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
        UserDefaults.standard.set(true, forKey: "HaulForcePro")
        defer { UserDefaults.standard.removeObject(forKey: "HaulForcePro") }
        let model = AppModel(store: store)
        guard model.gate.allows(.mediaGrabber) else { throw XCTSkip("the store edition has no grabber") }
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0", edition: .direct, features: .init(media: true)), delegate: model)
        let shown = expectation(description: "panel asked")
        model.onPending = { shown.fulfill() }
        _ = try await model.server(server, receive: IncomingDownload(url: "https://x/y.m3u8", kind: "hls", pageTitle: "A Clip"), media: true)
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertEqual(model.pending.first?.name, "A Clip")
        model.dismissCatch(model.pending.first!)
        XCTAssertTrue(model.pending.isEmpty)
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

    func testMediaNeedsPro() async throws {
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0", edition: .store, features: .init(media: false)), delegate: model)
        do {
            _ = try await model.server(server, receive: IncomingDownload(url: "https://x/y.m3u8", kind: "hls"), media: true)
            XCTFail("expected a refusal")
        } catch ServerError.badRequest(let message) {
            XCTAssertTrue(message.contains("Pro"))
        }
    }

    func testFlushWritesTheLibrary() throws {
        let model = AppModel(store: store)
        model.setAskBeforeStarting(false)
        model.flush()
        XCTAssertFalse(store.load().settings.askBeforeStarting)
    }
}
