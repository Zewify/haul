import Foundation

/// Enough of the HLS playlist format (RFC 8216) to download a finished stream: master playlists with variants,
/// media playlists with segments, AES-128 keys and an fMP4 init segment.
public enum HLS {
    public struct Variant: Hashable, Sendable {
        public var uri: URL
        public var bandwidth: Int
        public var resolution: String?
    }

    public struct Key: Hashable, Sendable {
        public var method: String
        public var uri: URL?
        public var iv: Data?
    }

    public struct MediaSegment: Hashable, Sendable {
        public var uri: URL
        public var duration: Double
        public var key: Key?
        public var sequence: Int
    }

    public enum Playlist: Hashable, Sendable {
        case master([Variant])
        case media(segments: [MediaSegment], map: URL?, endList: Bool)
    }

    public enum ParseError: Error, Equatable {
        case notAPlaylist
        /// SAMPLE-AES, FairPlay, Widevine: the stream is protected and cannot be saved.
        case drm
        case noSegments
    }

    public static func parse(_ text: String, base: URL) throws -> Playlist {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw ParseError.notAPlaylist }

        var variants: [Variant] = []
        var segments: [MediaSegment] = []
        var pendingVariant: [String: String]?
        var pendingDuration: Double?
        var key: Key?
        var map: URL?
        var endList = false
        var sequence = 0

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXTINF:") {
                let spec = line.dropFirst("#EXTINF:".count)
                pendingDuration = Double(spec.split(separator: ",", maxSplits: 1).first ?? "") ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                switch method {
                case "NONE": key = nil
                case "AES-128":
                    key = Key(method: method, uri: attrs["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }, iv: attrs["IV"].flatMap(hex))
                default: throw ParseError.drm
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                map = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                endList = true
            } else if line.hasPrefix("#EXT-X-SESSION-KEY:") {
                if attributes(String(line.dropFirst("#EXT-X-SESSION-KEY:".count)))["METHOD"] == "SAMPLE-AES" { throw ParseError.drm }
            } else if line.hasPrefix("#") {
                continue
            } else if let attrs = pendingVariant {
                pendingVariant = nil
                guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                variants.append(Variant(uri: uri, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0, resolution: attrs["RESOLUTION"]))
            } else if let duration = pendingDuration {
                pendingDuration = nil
                guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                segments.append(MediaSegment(uri: uri, duration: duration, key: key, sequence: sequence))
                sequence += 1
            }
        }
        if !variants.isEmpty { return .master(variants) }
        guard !segments.isEmpty else { throw ParseError.noSegments }
        return .media(segments: segments, map: map, endList: endList)
    }

    /// The variant with the highest bandwidth.
    public static func best(of variants: [Variant]) -> Variant? {
        variants.max { $0.bandwidth < $1.bandwidth }
    }

    /// `KEY=value,KEY2="quoted, value"` into a dictionary.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inQuotes = false, readingKey = true
        func commit() {
            if !key.isEmpty { result[key] = value }
            key = ""; value = ""; readingKey = true
        }
        for character in text {
            if readingKey {
                if character == "=" { readingKey = false } else { key.append(character) }
            } else if inQuotes {
                if character == "\"" { inQuotes = false } else { value.append(character) }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    static func hex(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
