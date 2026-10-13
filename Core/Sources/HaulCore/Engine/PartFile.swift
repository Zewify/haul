import Foundation

/// The `<name>.haulpart` file a download writes into, preallocated to its size so every segment can write at
/// its own offset; renamed to its final name when every segment is done.
public final class PartFile: Sendable {
    public let folder: URL
    public let name: String
    public let url: URL

    public init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
        self.url = folder.appendingPathComponent(Filename.partName(for: name))
    }

    /// Creates the file at `size` bytes, keeping an existing part of the same size (a resume). Without a size the
    /// file is left as it is, or created empty.
    public func prepare(size: Int64?) throws {
        let fm = FileManager.default
        if let size, fm.fileExists(atPath: url.path), length == size { return }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        guard let size else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    public var length: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Writes bytes at an offset. Each caller may hold its own handle; this opens one per call for simplicity
    /// where it is not on a hot path, and `writer()` gives a segment its own.
    public func write(_ data: Data, at offset: Int64) throws {
        let handle = try writer()
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    public func writer() throws -> FileHandle {
        try FileHandle(forWritingTo: url)
    }

    /// Renames the part to its final name, numbered if that name is now taken, and returns the result.
    public func finish() throws -> URL {
        let finalName = Filename.available(name, in: folder, ignoring: [url.lastPathComponent])
        let destination = folder.appendingPathComponent(finalName)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
