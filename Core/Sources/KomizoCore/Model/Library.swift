import Foundation
import os

/// A browser extension the user allowed to send downloads.
public struct PairedClient: Codable, Hashable, Sendable, Identifiable {
    public var client: String
    public var name: String
    public var paired: Date

    public init(client: String, name: String, paired: Date = Date()) {
        self.client = client
        self.name = name
        self.paired = paired
    }

    public var id: String { client + "|" + name }
}

public struct Settings: Codable, Hashable, Sendable {
    /// The folder downloads land in; nil means the user's Downloads folder.
    public var downloadFolderPath: String?
    /// The security-scoped bookmark for a folder the user chose, so the sandbox lets the app back in after a relaunch.
    public var downloadFolderBookmark: Data?
    public var askBeforeStarting: Bool
    public var connections: Int
    public var concurrent: Int
    public var port: UInt16
    public var openAtLogin: Bool
    public var pairingToken: String
    public var pairedClients: [PairedClient]
    /// Whether all downloads together are held to `speedLimit`; kept apart so the menu can toggle it without losing it.
    public var limitSpeed: Bool
    /// Bytes per second for everything at once, never below `SpeedLimiter.minimum`.
    public var speedLimit: Int64

    /// The cap the engine runs under: nil while the limit is off.
    public var effectiveSpeedLimit: Int64? { limitSpeed ? max(speedLimit, SpeedLimiter.minimum) : nil }

    public init() {
        askBeforeStarting = true
        connections = 4
        concurrent = 2
        port = 48512
        openAtLogin = false
        pairingToken = Settings.makeToken()
        pairedClients = []
        limitSpeed = false
        speedLimit = 2_000_000
    }

    /// 256 bits of randomness as base64url: the bearer token the extension sends with every download.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Base64URL.encode(Data(bytes))
    }

    // Every key but the token has a default, so a file from an older version still loads.
    private enum CodingKeys: String, CodingKey {
        case downloadFolderPath, downloadFolderBookmark, askBeforeStarting, connections, concurrent, port, openAtLogin,
             pairingToken, pairedClients, limitSpeed, speedLimit
    }

    public init(from decoder: Decoder) throws {
        let defaults = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadFolderPath = try c.decodeIfPresent(String.self, forKey: .downloadFolderPath)
        downloadFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .downloadFolderBookmark)
        askBeforeStarting = try c.decodeIfPresent(Bool.self, forKey: .askBeforeStarting) ?? defaults.askBeforeStarting
        connections = try c.decodeIfPresent(Int.self, forKey: .connections) ?? defaults.connections
        concurrent = try c.decodeIfPresent(Int.self, forKey: .concurrent) ?? defaults.concurrent
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? defaults.port
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? defaults.openAtLogin
        pairingToken = try c.decodeIfPresent(String.self, forKey: .pairingToken) ?? defaults.pairingToken
        pairedClients = try c.decodeIfPresent([PairedClient].self, forKey: .pairedClients) ?? []
        limitSpeed = try c.decodeIfPresent(Bool.self, forKey: .limitSpeed) ?? defaults.limitSpeed
        speedLimit = try c.decodeIfPresent(Int64.self, forKey: .speedLimit) ?? defaults.speedLimit
    }
}

/// Everything the app remembers: the downloads, in the order they were added, and the settings.
public struct Library: Codable, Hashable, Sendable {
    public var downloads: [Download]
    public var settings: Settings

    public init(downloads: [Download] = [], settings: Settings = Settings()) {
        self.downloads = downloads
        self.settings = settings
    }
}

/// Reads and writes the library as JSON, atomically. A missing or unreadable file is an empty library.
public final class LibraryStore: Sendable {
    public let url: URL
    private let log = Logger(subsystem: "com.zewify.komizo", category: "library")

    public init(url: URL) {
        self.url = url
    }

    /// `library.json` in the app's Application Support folder (inside the sandbox container when sandboxed).
    public static var standard: LibraryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LibraryStore(url: base.appendingPathComponent("Komizo", isDirectory: true).appendingPathComponent("library.json"))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public func load() -> Library {
        guard let data = try? Data(contentsOf: url) else { return Library() }
        do {
            return try Self.decoder.decode(Library.self, from: data)
        } catch {
            log.error("library.json unreadable, starting empty: \(error.localizedDescription)")
            return Library()
        }
    }

    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(library).write(to: url, options: .atomic)
    }
}
