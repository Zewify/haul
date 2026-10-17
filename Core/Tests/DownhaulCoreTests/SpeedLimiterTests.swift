import Foundation
import Testing
@testable import DownhaulCore

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func set(_ value: Int64) { lock.withLock { bytes = max(bytes, value) } }
    var value: Int64 { lock.withLock { bytes } }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

struct SpeedLimiterTests {
    @Test func noLimitNeverPauses() {
        let limiter = SpeedLimiter()
        #expect(limiter.take(10_000_000) == 0)
    }

    @Test func debtIsPaidAtTheCap() {
        let clock = FakeClock()
        let limiter = SpeedLimiter(bytesPerSecond: 100_000, now: clock.now)
        // A fresh cap has no credit: the first 50 KB costs half a second.
        #expect(abs(limiter.take(50_000) - 0.5) < 1e-9)
        // Two connections share one budget: the second chunk waits behind the first.
        #expect(abs(limiter.take(50_000) - 1.0) < 1e-9)
        clock.advance(1.0)
        #expect(limiter.take(0) == 0)
    }

    @Test func idleTimeEarnsAQuarterSecondOfCreditAtMost() {
        let clock = FakeClock()
        let limiter = SpeedLimiter(bytesPerSecond: 100_000, now: clock.now)
        clock.advance(60)
        #expect(limiter.take(25_000) == 0)
        #expect(abs(limiter.take(10_000) - 0.1) < 1e-9)
    }

    @Test func aNewCapAppliesFromTheNextChunk() {
        let clock = FakeClock()
        let limiter = SpeedLimiter(bytesPerSecond: 100_000, now: clock.now)
        limiter.bytesPerSecond = nil
        #expect(limiter.take(1_000_000) == 0)
        limiter.bytesPerSecond = 1_000_000
        #expect(abs(limiter.take(500_000) - 0.5) < 1e-9)
        #expect(limiter.bytesPerSecond == 1_000_000)
    }
}

/// The cap holds on real transfers: a file over several connections, a stream's segments, and a cap lifted mid-way.
struct SpeedLimitTransferTests {
    let server: TestServer
    let folder: URL

    init() throws {
        server = try TestServer()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("downhaul-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func fileDownload(_ name: String, size: Int) throws -> Download {
        server["/\(name)"] = .init(data: TestServer.blob(size, seed: 3))
        var download = Download(url: server.url("/\(name)"), name: name, folder: folder)
        download.finalURL = download.url
        return download
    }

    @Test func aFileOverFourConnectionsStaysUnderTheCap() async throws {
        let download = try fileDownload("capped.bin", size: 600_000)
        let limiter = SpeedLimiter(bytesPerSecond: 200_000)
        let started = Date()
        let result = await DownloadTask(download: download, connections: 4, session: .shared, limiter: limiter, retryDelays: [0.05]) { _ in }.run()
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.state == .finished)
        // 600 KB at 200 KB/s is three seconds, less the quarter second of credit the bucket can hold.
        #expect(elapsed > 2.5, "took \(elapsed)s")
        #expect(elapsed < 6, "took \(elapsed)s")
        #expect(try Data(contentsOf: URL(fileURLWithPath: try #require(result.finalPath))) == TestServer.blob(600_000, seed: 3))
    }

    /// The first seconds are where a cap used to leak: whole socket buffers arriving as one chunk, written at once.
    @Test func noBurstAtTheStart() async throws {
        let download = try fileDownload("burst.bin", size: 4_000_000)
        let written = ByteCounter()
        let task = DownloadTask(download: download, connections: 4, session: .shared, limiter: SpeedLimiter(bytesPerSecond: 1_000_000), retryDelays: [0.05]) { progress in
            written.set(progress.bytes)
        }
        let running = Task { await task.run() }
        try await Task.sleep(for: .seconds(1))
        // One second at 1 MB/s, plus the quarter second of credit and a slice per connection in flight.
        #expect(written.value < 1_600_000, "wrote \(written.value) bytes in the first second")
        await task.cancel()
        _ = await running.value
    }

    @Test func liftingTheCapSpeedsARunningDownloadUp() async throws {
        let download = try fileDownload("lifted.bin", size: 2_000_000)
        let limiter = SpeedLimiter(bytesPerSecond: 100_000)
        let started = Date()
        let task = DownloadTask(download: download, connections: 2, session: .shared, limiter: limiter, retryDelays: [0.05]) { _ in }
        Task { try? await Task.sleep(for: .seconds(1)); limiter.bytesPerSecond = nil }
        let result = await task.run()
        // At the cap the whole file would take twenty seconds.
        #expect(result.state == .finished)
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func pausingACappedDownloadDoesNotWaitOutTheCap() async throws {
        let download = try fileDownload("paused.bin", size: 2_000_000)
        let task = DownloadTask(download: download, connections: 2, session: .shared, limiter: SpeedLimiter(bytesPerSecond: 100_000), retryDelays: [0.05]) { _ in }
        Task { try? await Task.sleep(for: .seconds(0.8)); await task.pause() }
        let started = Date()
        let result = await task.run()
        #expect(result.state == .paused)
        // Waiting out the cap would take twenty seconds; a pause that cuts the wait short is back in a few.
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func aStreamsSegmentsShareTheCap() async throws {
        for n in 1...4 { server["/s\(n).ts"] = .init(data: TestServer.blob(100_000, seed: UInt64(n))) }
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\ns1.ts\n#EXTINF:4,\ns2.ts\n#EXTINF:4,\ns3.ts\n#EXTINF:4,\ns4.ts\n#EXT-X-ENDLIST\n".utf8))
        let download = Download(url: server.url("/media.m3u8"), kind: .hls, name: "capped", folder: folder)
        let started = Date()
        let result = await StreamTask(download: download, session: .shared, limiter: SpeedLimiter(bytesPerSecond: 200_000), retryDelays: [0.05]) { _ in }.run()
        let elapsed = Date().timeIntervalSince(started)
        #expect(result.state == .finished)
        #expect(elapsed > 1.5, "took \(elapsed)s")
    }
}
