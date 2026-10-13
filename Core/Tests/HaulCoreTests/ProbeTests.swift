import Foundation
import Testing
@testable import HaulCore

struct ProbeTests {
    let server: TestServer
    let blob = TestServer.blob(300_000)

    init() throws {
        server = try TestServer()
        server["/blob.bin"] = TestServer.Resource(data: blob)
    }

    @Test func learnsSizeRangesValidatorAndName() async throws {
        let result = try await Probe.run(server.url("/blob.bin"), context: RequestContext(), session: .shared)
        #expect(result.size == 300_000)
        #expect(result.acceptsRanges)
        #expect(result.validator == "\"v1\"")
        #expect(result.suggestedName == "blob.bin")
        #expect(result.contentType == "application/octet-stream")
        #expect(result.finalURL == server.url("/blob.bin"))
        #expect(server.requests.last?.headers["range"] == "bytes=0-0")
    }

    @Test func noRangeSupportStillReportsSize() async throws {
        server.supportsRanges = false
        let result = try await Probe.run(server.url("/blob.bin"), context: RequestContext(), session: .shared)
        #expect(result.size == 300_000)
        #expect(!result.acceptsRanges)
    }

    @Test func hiddenLengthGivesNilSize() async throws {
        server.hidesLength = true
        server.supportsRanges = false
        let result = try await Probe.run(server.url("/blob.bin"), context: RequestContext(), session: .shared)
        #expect(result.size == nil)
        #expect(!result.acceptsRanges)
    }

    @Test func probeFollowsRedirectAndFallsBack() async throws {
        server.supportsRanges = false
        server["/redirect"] = TestServer.Resource(data: Data(), headers: ["Location": server.url("/blob.bin").absoluteString], status: 302)
        let result = try await Probe.run(server.url("/redirect"), context: RequestContext(), session: .shared)
        #expect(result.finalURL == server.url("/blob.bin"))
        #expect(result.size == 300_000)
        #expect(!result.acceptsRanges)
        #expect(result.suggestedName == "blob.bin")
    }

    @Test func dispositionBeatsURL() async throws {
        server["/dl"] = TestServer.Resource(data: blob, headers: ["Content-Disposition": "attachment; filename=\"Real Name.zip\""])
        let result = try await Probe.run(server.url("/dl"), context: RequestContext(), session: .shared)
        #expect(result.suggestedName == "Real Name.zip")
    }

    @Test func contextHeadersAreSent() async throws {
        let context = RequestContext(referrer: "https://ref.example/", cookies: "s=1; t=2", userAgent: "HaulTest/1", headers: ["X-Extra": "yes"])
        _ = try await Probe.run(server.url("/blob.bin"), context: context, session: .shared)
        let headers = try #require(server.requests.last?.headers)
        #expect(headers["referer"] == "https://ref.example/")
        #expect(headers["cookie"] == "s=1; t=2")
        #expect(headers["user-agent"] == "HaulTest/1")
        #expect(headers["x-extra"] == "yes")
    }

    @Test func missingFileThrows() async {
        await #expect(throws: ProbeError.self) {
            try await Probe.run(server.url("/nope"), context: RequestContext(), session: .shared)
        }
    }
}
