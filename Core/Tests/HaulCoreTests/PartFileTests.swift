import Foundation
import Testing
@testable import HaulCore

struct PartFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("haul-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func preallocatesAndWritesAtOffsets() throws {
        let part = PartFile(folder: folder, name: "a.bin")
        try part.prepare(size: 100)
        #expect(part.url.lastPathComponent == "a.bin.haulpart")
        #expect(part.length == 100)
        try part.write(Data([1, 2, 3]), at: 10)
        try part.write(Data([9]), at: 99)
        let bytes = try Data(contentsOf: part.url)
        #expect(bytes.count == 100)
        #expect(bytes[10...12] == Data([1, 2, 3]))
        #expect(bytes[99] == 9)
    }

    @Test func prepareWithoutSizeStartsEmptyAndGrows() throws {
        let part = PartFile(folder: folder, name: "stream.bin")
        try part.prepare(size: nil)
        #expect(part.length == 0)
        try part.write(Data([1, 2]), at: 0)
        try part.write(Data([3]), at: 2)
        #expect(part.length == 3)
    }

    @Test func prepareKeepsAnExistingPartFileOfTheRightSize() throws {
        let part = PartFile(folder: folder, name: "keep.bin")
        try part.prepare(size: 50)
        try part.write(Data([7]), at: 5)
        let again = PartFile(folder: folder, name: "keep.bin")
        try again.prepare(size: 50)
        #expect(try Data(contentsOf: again.url)[5] == 7)
    }

    @Test func finishRenamesAndNumbersCollisions() throws {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("a.bin").path, contents: Data())
        let part = PartFile(folder: folder, name: "a.bin")
        try part.prepare(size: 3)
        try part.write(Data([1, 2, 3]), at: 0)
        let final = try part.finish()
        #expect(final.lastPathComponent == "a 2.bin")
        #expect(try Data(contentsOf: final) == Data([1, 2, 3]))
        #expect(!FileManager.default.fileExists(atPath: part.url.path))
    }

    @Test func finishKeepsTheNameWhenNothingCollides() throws {
        let part = PartFile(folder: folder, name: "clean.bin")
        try part.prepare(size: 1)
        #expect(try part.finish().lastPathComponent == "clean.bin")
    }

    @Test func removeDeletesThePart() throws {
        let part = PartFile(folder: folder, name: "gone.bin")
        try part.prepare(size: 3)
        part.remove()
        #expect(!FileManager.default.fileExists(atPath: part.url.path))
    }
}
