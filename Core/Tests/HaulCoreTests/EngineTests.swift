import Foundation
import Testing
@testable import HaulCore

@MainActor
struct EngineTests {
    let server: TestServer
    let folder: URL
    let blob = TestServer.blob(2 << 20)

    init() throws {
        server = try TestServer()
        server["/a.bin"] = TestServer.Resource(data: blob)
        server["/b.bin"] = TestServer.Resource(data: blob)
        server["/c.bin"] = TestServer.Resource(data: blob)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func engine(concurrent: Int = 2) -> DownloadEngine {
        DownloadEngine(downloads: [], gate: FeatureGate(edition: .store, isPro: false), connections: 2, concurrent: concurrent, folder: folder, retryDelays: [0.05])
    }

    func request(_ path: String, name: String? = nil) -> Download {
        Download(url: server.url(path), name: name ?? String(path.dropFirst()), folder: folder)
    }

    /// Polls until the condition holds or two seconds pass.
    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func queueRunsTwoAtATimeAndStartsTheThirdWhenOneFinishes() async throws {
        server.chunkDelayMs = 15
        let engine = engine(concurrent: 2)
        let a = engine.add(request("/a.bin"))
        let b = engine.add(request("/b.bin"))
        let c = engine.add(request("/c.bin"))
        #expect(await eventually { engine.download(a)?.state.isRunning == true && engine.download(b)?.state.isRunning == true })
        #expect(engine.download(c)?.state == .queued)
        server.chunkDelayMs = 0
        #expect(await eventually { engine.download(a)?.state == .finished })
        #expect(await eventually { engine.download(c)?.state.isRunning == true || engine.download(c)?.state == .finished })
        #expect(await eventually { engine.downloads.allSatisfy { $0.state == .finished } })
        #expect(try Data(contentsOf: URL(fileURLWithPath: engine.download(c)!.finalPath!)) == blob)
    }

    @Test func pauseAllAndResumeAll() async throws {
        server.chunkDelayMs = 15
        let engine = engine(concurrent: 2)
        let a = engine.add(request("/a.bin"))
        let c = engine.add(request("/c.bin"))
        _ = engine.add(request("/b.bin"))
        #expect(await eventually { engine.download(a)?.state == .downloading })
        engine.pauseAll()
        #expect(await eventually { engine.downloads.allSatisfy { $0.state == .paused } })
        #expect(engine.downloads.allSatisfy { $0.state == .paused })
        server.chunkDelayMs = 0
        engine.resumeAll()
        #expect(await eventually { engine.downloads.allSatisfy { $0.state == .finished } })
        _ = c
    }

    @Test func pausingAQueuedDownloadKeepsItOutOfTheQueue() async throws {
        server.chunkDelayMs = 15
        let engine = engine(concurrent: 1)
        let a = engine.add(request("/a.bin"))
        let b = engine.add(request("/b.bin"))
        #expect(await eventually { engine.download(a)?.state.isRunning == true })
        engine.pause(b)
        #expect(engine.download(b)?.state == .paused)
        server.chunkDelayMs = 0
        #expect(await eventually { engine.download(a)?.state == .finished })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.download(b)?.state == .paused)
        engine.resume(b)
        #expect(await eventually { engine.download(b)?.state == .finished })
    }

    @Test func removeWithDeleteRemovesTheFile() async throws {
        let engine = engine()
        let a = engine.add(request("/a.bin"))
        #expect(await eventually { engine.download(a)?.state == .finished })
        let path = engine.download(a)!.finalPath!
        #expect(FileManager.default.fileExists(atPath: path))
        engine.remove(a, deleteFile: true)
        #expect(engine.download(a) == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func cancelWhileRunningRemovesThePart() async throws {
        server.chunkDelayMs = 15
        let engine = engine()
        let a = engine.add(request("/a.bin"))
        #expect(await eventually { (engine.progress(for: a)?.bytes ?? 0) > 0 })
        engine.cancel(a)
        #expect(await eventually { engine.download(a)?.state == .cancelled })
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin.haulpart").path))
        engine.retry(a)
        #expect(await eventually { engine.download(a)?.state == .finished })
    }

    @Test func concurrentSameNameGetsDistinctPartFiles() async throws {
        server.chunkDelayMs = 15
        let engine = engine()
        let first = engine.add(request("/a.bin", name: "same.bin"))
        let second = engine.add(request("/b.bin", name: "same.bin"))
        #expect(engine.download(first)?.name == "same.bin")
        #expect(engine.download(second)?.name == "same 2.bin")
        server.chunkDelayMs = 0
        #expect(await eventually { engine.downloads.allSatisfy { $0.state == .finished } })
        #expect(engine.download(first)?.finalPath?.hasSuffix("/same.bin") == true)
        #expect(engine.download(second)?.finalPath?.hasSuffix("/same 2.bin") == true)
    }

    @Test func interruptedDownloadsLoadAsPausedAndQueuedOnesStart() async throws {
        var interrupted = request("/a.bin")
        interrupted.state = .downloading
        var queued = request("/b.bin")
        queued.state = .queued
        let engine = DownloadEngine(downloads: [interrupted, queued], gate: FeatureGate(edition: .store, isPro: false), connections: 2, concurrent: 2, folder: folder, retryDelays: [0.05])
        #expect(engine.download(interrupted.id)?.state == .paused)
        #expect(await eventually { engine.download(queued.id)?.state == .finished })
    }

    @Test func hlsDownloadsSaveOneFile() async throws {
        let a = Data("AAAA".utf8), b = Data("BBBB".utf8)
        server["/a.ts"] = .init(data: a)
        server["/b.ts"] = .init(data: b)
        server["/media.m3u8"] = .init(data: Data("#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST\n".utf8))
        let engine = engine()
        var request = request("/media.m3u8", name: "Clip")
        request.kind = .hls
        let id = engine.add(request)
        #expect(await eventually { engine.download(id)?.state == .finished })
        let done = try #require(engine.download(id))
        #expect(done.finalPath?.hasSuffix("/Clip.ts") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: done.finalPath!)) == a + b)
        #expect(done.mediaDone == 2)
        #expect(done.mediaTotal == 2)
        #expect(done.fraction == 1)
    }

    @Test func pauseAndCancelWhileProbingAreHonoured() async throws {
        server.responseDelayMs = 400
        let engine = engine()
        let a = engine.add(request("/a.bin"))
        let b = engine.add(request("/b.bin"))
        #expect(engine.download(a)?.state == .probing)
        engine.pause(a)
        engine.cancel(b)
        #expect(await eventually { engine.download(a)?.state == .paused && engine.download(b)?.state == .cancelled })
        try? await Task.sleep(for: .seconds(1))
        #expect(engine.download(a)?.state == .paused)
        #expect(engine.download(b)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.bin.haulpart").path))
    }

    @Test func removeWhileProbingDoesNotLeaveAnOrphanFile() async throws {
        server.responseDelayMs = 400
        let engine = engine()
        let a = engine.add(request("/a.bin"))
        engine.remove(a, deleteFile: true)
        try? await Task.sleep(for: .seconds(1.5))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.bin.haulpart").path))
    }

    @Test func retryingAFailedDownloadNeverTouchesAnotherDownloadsPart() async throws {
        let engine = engine()
        let failed = engine.add(request("/nope", name: "same.bin"))
        #expect(await eventually { if case .failed = engine.download(failed)?.state { true } else { false } })
        server.chunkDelayMs = 15
        let working = engine.add(request("/a.bin", name: "same.bin"))
        #expect(engine.download(working)?.name == "same.bin")
        #expect(await eventually { (engine.progress(for: working)?.bytes ?? 0) > 0 })
        server["/nope"] = TestServer.Resource(data: blob)
        engine.retry(failed)
        server.chunkDelayMs = 0
        #expect(await eventually { engine.downloads.allSatisfy { $0.state == .finished } })
        let w = try #require(engine.download(working))
        #expect(w.finalPath?.hasSuffix("/same.bin") == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: w.finalPath!)) == blob)
        #expect(engine.download(failed)?.finalPath?.hasSuffix("/same 2.bin") == true)
    }

    @Test func aFolderBookmarkIsResolvedBeforeAnythingIsWritten() async throws {
        let real = folder.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        var download = request("/a.bin")
        download.folder = URL(fileURLWithPath: "/nonexistent/stale/path")
        download.folderBookmark = try real.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let engine = engine()
        let id = engine.add(download)
        #expect(engine.download(id)?.folder.standardizedFileURL == real.standardizedFileURL)
        #expect(await eventually { engine.download(id)?.state == .finished })
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("a.bin").path))
    }

    @Test func removeIfDoneLeavesActiveAndPausedDownloadsAlone() async throws {
        server.chunkDelayMs = 15
        let engine = engine()
        let a = engine.add(request("/a.bin"))
        engine.removeIfDone(a)
        #expect(engine.download(a) != nil)
        engine.pause(a)
        #expect(await eventually { engine.download(a)?.state == .paused })
        engine.removeIfDone(a)
        #expect(engine.download(a) != nil)
        server.chunkDelayMs = 0
        engine.resume(a)
        #expect(await eventually { engine.download(a)?.state == .finished })
        engine.removeIfDone(a)
        #expect(engine.download(a) == nil)
    }

    @Test func changesAreReported() async throws {
        let engine = engine()
        let counter = Flag()
        engine.onChange = { counter.set() }
        _ = engine.add(request("/a.bin"))
        #expect(counter.isSet)
    }

    @Test func combinedProgressSumsActiveDownloads() async throws {
        server.chunkDelayMs = 15
        let engine = engine()
        _ = engine.add(request("/a.bin"))
        _ = engine.add(request("/b.bin"))
        #expect(await eventually { engine.combined.fraction ?? 0 > 0 })
        let combined = engine.combined
        #expect(combined.fraction! < 1)
        #expect(combined.bytesPerSecond >= 0)
    }
}
