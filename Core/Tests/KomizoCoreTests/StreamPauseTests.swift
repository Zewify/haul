import Foundation
import Testing
@testable import KomizoCore

/// A stream download paused mid-segment must pause, and resume to the exact file. It once ignored the pause and wrote
/// the cut-off segments as if whole (a Dailymotion file with a broken packet a fifth of the way in), or, when the pause
/// came before a segment's headers, failed with "Not an HTTP response."
struct StreamPauseTests {
    let server: TestServer
    let folder: URL
    let segments = (1...4).map { TestServer.blob(2_000_000, seed: UInt64($0)) }

    init() throws {
        server = try TestServer()
        server.chunkDelayMs = 20
        for (n, data) in segments.enumerated() { server["/s\(n + 1).ts"] = .init(data: data) }
        server["/m.m3u8"] = .init(data: Data(("#EXTM3U\n" + (1...4).map { "#EXTINF:4,\ns\($0).ts\n" }.joined() + "#EXT-X-ENDLIST\n").utf8))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("komizo-pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func pausingMidSegmentPausesAndResumingGivesTheExactFile() async throws {
        let task = StreamTask(download: Download(url: server.url("/m.m3u8"), kind: .hls, name: "clip", folder: folder), session: .shared, retryDelays: [0.05]) { _ in }
        Task { try? await Task.sleep(for: .milliseconds(250)); await task.pause() }
        let paused = await task.run()
        #expect(paused.state == .paused)
        server.chunkDelayMs = 0
        let done = await StreamTask(download: paused, session: .shared, retryDelays: [0.05]) { _ in }.run()
        #expect(done.state == .finished)
        let path = try #require(done.finalPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == segments.reduce(Data(), +))
    }

    @Test func aConnectionThatGivesNoResponseIsRetriedNotFailed() async throws {
        // The first request is cut before any headers; the retry gets the file.
        server.dropAfterBytes = 0
        server.dropTimes = 1
        let fetcher = MediaFetcher(context: RequestContext(), session: .shared, retryDelays: [0.05])
        #expect(try await fetcher.data(server.url("/s1.ts")) == segments[0])
    }
}
