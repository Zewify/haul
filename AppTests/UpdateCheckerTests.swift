import HaulCore
import XCTest
@testable import Haul

@MainActor
final class UpdateCheckerTests: XCTestCase {
    nonisolated(unsafe) var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "haul-updates-\(UUID().uuidString)")
    }

    static func feed(_ tag: String, status: Int = 200) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            XCTAssertEqual(request.url, UpdateChecker.feed)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"tag_name":"\#(tag)"}"#.utf8), response)
        }
    }

    func testANewerReleaseIsOfferedAndRememberedAcrossLaunches() async {
        let checker = UpdateChecker(defaults: defaults, current: "0.2.0", fetch: Self.feed("v0.3.0"))
        await checker.check(force: false)
        XCTAssertEqual(checker.available?.description, "0.3.0")
        let relaunched = UpdateChecker(defaults: defaults, current: "0.2.0", fetch: Self.feed("v9.9.9"))
        XCTAssertEqual(relaunched.available?.description, "0.3.0", "known before any new check")
        await relaunched.check(force: false)
        XCTAssertEqual(relaunched.available?.description, "0.3.0", "checked once a day, not on every launch")
    }

    func testTheSameOrAnOlderReleaseOffersNothing() async {
        let checker = UpdateChecker(defaults: defaults, current: "0.2.0", fetch: Self.feed("v0.2.0"))
        await checker.check(force: true)
        XCTAssertNil(checker.available)
    }

    func testAFailedCheckTriesAgainAndOffClearsTheOffer() async {
        let offline = UpdateChecker(defaults: defaults, current: "0.2.0") { _ in throw URLError(.notConnectedToInternet) }
        await offline.check(force: false)
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheck"), "no response, so the day is not used up")
        let checker = UpdateChecker(defaults: defaults, current: "0.2.0", fetch: Self.feed("v1.0.0"))
        await checker.check(force: false)
        XCTAssertNotNil(checker.available)
        checker.isEnabled = false
        XCTAssertNil(checker.available)
    }
}
