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
