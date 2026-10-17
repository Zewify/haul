import Foundation
import Testing
@testable import KomizoCore

struct DownloadTaskTests {
    let server: TestServer
    let folder: URL
    let blob = TestServer.blob(6 << 20)
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 64
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    let quickRetries: [TimeInterval] = [0.05, 0.05, 0.05, 0.05, 0.05]

    init() throws {
        server = try TestServer()
        server["/blob.bin"] = TestServer.Resource(data: blob)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("komizo-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func download(_ path: String = "/blob.bin") -> Download {
        Download(url: server.url(path), name: "", folder: folder)
    }

    func run(_ download: Download, connections: Int = 4, onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async -> Download {
        let task = DownloadTask(download: download, connections: connections, session: session, retryDelays: quickRetries, onProgress: onProgress)
        return await task.run()
    }

    func fileMatches(_ result: Download) throws -> Bool {
        let path = try #require(result.finalPath)
        return try Data(contentsOf: URL(fileURLWithPath: path)) == blob
    }

    /// Bytes the server was asked for after the probe, from the recorded `Range` headers.
    func bytesRequested(_ ranges: [String]) -> Int64 {
        ranges.reduce(0) { sum, range in
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard spec.count == 2, let a = Int64(spec[0]) else { return sum }
            let b = Int64(spec[1]) ?? Int64(blob.count - 1)
            if a == 0 && b == 0 { return sum }
            return sum + (b - a + 1)
        }
    }

    @Test func segmentedDownloadIsByteIdentical() async throws {
        let result = await run(download())
        #expect(result.state == .finished)
        #expect(result.name == "blob.bin")
        #expect(result.size == Int64(blob.count))
        #expect(result.resumable)
        #expect(result.segments.count == 4)
        #expect(result.segments.allSatisfy { $0.isComplete })
        #expect(try fileMatches(result))
        #expect(result.finalPath?.hasSuffix("/blob.bin") == true)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("blob.bin.komizopart").path))
        #expect(server.rangesRequested.filter { $0 != "bytes=0-0" }.count >= 4)
    }

    @Test func singleStreamWhenRangesUnsupported() async throws {
        server.supportsRanges = false
        let result = await run(download())
        #expect(result.state == .finished)
        #expect(!result.resumable)
        #expect(result.segments.count == 1)
        #expect(try fileMatches(result))
    }

    @Test func unknownSizeStreamsToTheEnd() async throws {
        server.supportsRanges = false
        server.hidesLength = true
        let flag = Flag()
        let result = await run(download()) { progress in if progress.total == nil { flag.set() } }
        #expect(result.state == .finished)
        #expect(result.size == Int64(blob.count))
        #expect(flag.isSet)
        #expect(try fileMatches(result))
    }

    @Test func pauseAndResumeContinueWhereTheyStopped() async throws {
        server.chunkDelayMs = 20
        let holder = TaskHolder()
        let task = DownloadTask(download: download(), connections: 4, session: session, retryDelays: quickRetries) { progress in
            if progress.bytes >= 1 << 20 { Task { await holder.task?.pause() } }
        }
        await holder.set(task)
        let paused = await task.run()
        #expect(paused.state == .paused)
        #expect(paused.bytesReceived >= 1 << 20)
        #expect(paused.bytesReceived < Int64(blob.count))
        #expect(FileManager.default.fileExists(atPath: paused.partPath ?? ""))

        server.chunkDelayMs = 0
        server.clearRequests()
        let result = await run(paused)
        #expect(result.state == .finished)
        #expect(try fileMatches(result))
        let requested = bytesRequested(server.rangesRequested)
        #expect(requested <= Int64(blob.count) - paused.bytesReceived + 4 * 65536)
    }

    @Test func droppedConnectionRecovers() async throws {
        server.dropAfterBytes = 200_000
        server.dropTimes = 3
        let result = await run(download())
        #expect(result.state == .finished)
        #expect(try fileMatches(result))
        #expect(server.rangesRequested.count > 5)
    }

    @Test func resumeTrustsPartFileOverCounts() async throws {
        server.chunkDelayMs = 20
        let holder = TaskHolder()
        let task = DownloadTask(download: download(), connections: 4, session: session, retryDelays: quickRetries) { progress in
            if progress.bytes >= 1 << 20 { Task { await holder.task?.pause() } }
        }
        await holder.set(task)
        var paused = await task.run()
        #expect(paused.state == .paused)
        // A crash left the part file short of what the counts claim.
        let part = URL(fileURLWithPath: try #require(paused.partPath))
        try Data(count: 1000).write(to: part)
        paused.segments[0].written = max(paused.segments[0].written, 500_000)
        server.chunkDelayMs = 0
        let result = await run(paused)
        #expect(result.state == .finished)
        #expect(try fileMatches(result))
    }

    @Test func changedFileOnServerRestartsFromZero() async throws {
        server.chunkDelayMs = 20
        let holder = TaskHolder()
        let task = DownloadTask(download: download(), connections: 2, session: session, retryDelays: quickRetries) { progress in
            if progress.bytes >= 1 << 20 { Task { await holder.task?.pause() } }
        }
        await holder.set(task)
        let paused = await task.run()
        #expect(paused.state == .paused)
        let newBlob = TestServer.blob(6 << 20, seed: 2)
        server["/blob.bin"] = TestServer.Resource(data: newBlob)
        server.etag = "\"v2\""
        server.chunkDelayMs = 0
        server.clearRequests()
        let result = await run(paused, connections: 2)
        #expect(result.state == .finished)
        let finalPath = try #require(result.finalPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: finalPath)) == newBlob)
        #expect(server.rangesRequested.contains { $0.hasPrefix("bytes=0-") && $0 != "bytes=0-0" })
    }

    @Test func idleConnectionTakesOverTheTailOfABusyOne() async throws {
        let mib: Int64 = 1 << 20
        var download = download()
        download.finalURL = download.url
        download.size = 6 * mib
        download.resumable = true
        download.validator = "\"v1\""
        download.name = "blob.bin"
        download.segments = [Segment(start: 0, end: mib - 1), Segment(start: mib, end: 6 * mib - 1)]
        try PartFile(folder: folder, name: "blob.bin").prepare(size: 6 * mib)
        server.chunkDelayMs = 2
        let result = await run(download, connections: 2)
        #expect(result.state == .finished)
        #expect(try fileMatches(result))
        #expect(result.segments.count >= 3)
        let starts = server.rangesRequested.compactMap { Int64($0.dropFirst("bytes=".count).split(separator: "-")[0]) }
        #expect(starts.contains { $0 > mib })
    }

    @Test func missingFileFails() async throws {
        var download = download("/nope")
        download.name = "nope.bin"
        // The engine claims the part file at add time; a failure before any byte arrives must not leave it behind.
        try PartFile(folder: folder, name: "nope.bin").prepare(size: nil)
        let result = await run(download)
        guard case .failed(let message) = result.state else { Issue.record("expected failure, got \(result.state)"); return }
        #expect(message.contains("404"))
        #expect(result.partPath == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("nope.bin.komizopart").path))
    }

    @Test func cancelRemovesThePartFile() async throws {
        server.chunkDelayMs = 20
        let holder = TaskHolder()
        let task = DownloadTask(download: download(), connections: 4, session: session, retryDelays: quickRetries) { progress in
            if progress.bytes >= 256 << 10 { Task { await holder.task?.cancel() } }
        }
        await holder.set(task)
        let result = await task.run()
        #expect(result.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("blob.bin.komizopart").path))
    }

    @Test func segmentsAskForIdentityAndKeepCookiesOnTheOriginalHostOnly() async throws {
        let elsewhere = URL(string: "http://localhost:\(server.port)/blob.bin")!
        server["/away"] = TestServer.Resource(data: Data(), headers: ["Location": elsewhere.absoluteString], status: 302)
        var download = download("/away")
        download.context = RequestContext(cookies: "sid=abc", userAgent: "KomizoTest")
        let result = await run(download)
        #expect(result.state == .finished)
        #expect(try fileMatches(result))
        let fetches = server.requests.filter { $0.path == "/blob.bin" }
        #expect(fetches.count >= 4)
        #expect(fetches.allSatisfy { $0.headers["cookie"] == nil && $0.headers["accept-encoding"] == "identity" && $0.headers["user-agent"] == "KomizoTest" })
    }

    @Test func contextHeadersReachEverySegment() async throws {
        var download = download()
        download.context = RequestContext(cookies: "sid=abc", userAgent: "KomizoTest")
        _ = await run(download)
        let fetches = server.requests.filter { $0.headers["range"] != "bytes=0-0" }
        #expect(!fetches.isEmpty)
        #expect(fetches.allSatisfy { $0.headers["cookie"] == "sid=abc" && $0.headers["user-agent"] == "KomizoTest" })
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

actor TaskHolder {
    var task: DownloadTask?
    func set(_ task: DownloadTask) { self.task = task }
}
