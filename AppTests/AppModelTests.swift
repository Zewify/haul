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

    func testIncomingDownloadWaitsInThePanelWhenAskingIsOn() async throws {
        let model = AppModel(store: store)
        let server = ExtensionServer(port: 0, token: "t", status: ServerStatus(version: "0", edition: .store, features: .init(media: false)), delegate: model)
        let shown = expectation(description: "panel asked")
        model.onPending = { shown.fulfill() }
        let incoming = IncomingDownload(url: "http://127.0.0.1:1/nothing.zip", filename: "nothing.zip")
        _ = try await model.server(server, receive: incoming, media: false)
        await fulfillment(of: [shown], timeout: 5)
        XCTAssertEqual(model.pending.count, 1)
        XCTAssertEqual(model.pending.first?.name, "nothing.zip")
        XCTAssertNotNil(model.pending.first?.error, "an unreachable server is reported, not hidden")
        XCTAssertTrue(model.engine.downloads.isEmpty)
        model.dismissCatch(model.pending.first!)
        XCTAssertTrue(model.pending.isEmpty)
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
