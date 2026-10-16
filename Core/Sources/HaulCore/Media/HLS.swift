import Foundation

/// Enough of the HLS playlist format (RFC 8216) to download a finished stream: master playlists with variants and
/// their separate audio renditions, media playlists with segments, byte ranges, AES-128 keys and an fMP4 init segment.
public enum HLS {
    public struct Variant: Hashable, Sendable {
        public var uri: URL
        public var bandwidth: Int
        public var resolution: String?
        /// The `GROUP-ID` of the audio renditions this variant plays with, when the site keeps sound apart.
        public var audioGroup: String?
    }

    /// An `EXT-X-MEDIA` audio rendition. One without a URI means the sound is inside the variant itself.
    public struct Rendition: Hashable, Sendable {
        public var groupId: String
        public var uri: URL?
        public var name: String?
        public var language: String?
        public var isDefault: Bool
        public var autoselect: Bool
    }

    public struct Key: Hashable, Sendable {
        public var method: String
        public var uri: URL?
        public var iv: Data?
    }

    public enum Playlist: Hashable, Sendable {
        case master([Variant], audio: [Rendition])
        case media(segments: [StreamSegment], map: StreamSegment?, endList: Bool)
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
        var renditions: [Rendition] = []
        var segments: [StreamSegment] = []
        var pendingVariant: [String: String]?
        var pendingDuration: Double?
        var pendingRange: (length: Int64, offset: Int64?)?
        /// Where the last byte-range segment ended, in which file: a range with no offset carries on from there.
        var lastRange: (uri: URL, end: Int64)?
        var key: Key?
        var map: StreamSegment?
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
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                guard attrs["TYPE"] == "AUDIO", let group = attrs["GROUP-ID"] else { continue }
                renditions.append(Rendition(groupId: group, uri: attrs["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                                            name: attrs["NAME"], language: attrs["LANGUAGE"], isDefault: attrs["DEFAULT"] == "YES", autoselect: attrs["AUTOSELECT"] == "YES"))
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                map = attrs["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }.map { uri in
                    let range = attrs["BYTERANGE"].flatMap(byteRange).map { ($0.offset ?? 0)...(($0.offset ?? 0) + $0.length - 1) }
                    return StreamSegment(uri: uri, range: range)
                }
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
                variants.append(Variant(uri: uri, bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0, resolution: attrs["RESOLUTION"], audioGroup: attrs["AUDIO"]))
            } else if let duration = pendingDuration {
                pendingDuration = nil
                guard let uri = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                var range: ClosedRange<Int64>?
                if let pending = pendingRange {
                    pendingRange = nil
                    let start = pending.offset ?? (lastRange?.uri == uri ? lastRange!.end + 1 : 0)
                    range = start...(start + pending.length - 1)
                    lastRange = (uri, range!.upperBound)
                }
                segments.append(StreamSegment(uri: uri, range: range, duration: duration, key: key, sequence: sequence))
                sequence += 1
            }
        }
        if !variants.isEmpty { return .master(variants, audio: renditions) }
        guard !segments.isEmpty else { throw ParseError.noSegments }
        return .media(segments: segments, map: map, endList: endList)
    }

    /// The variant with the highest bandwidth.
    public static func best(of variants: [Variant]) -> Variant? {
        variants.max { $0.bandwidth < $1.bandwidth }
    }

    /// The separate audio a variant plays with: its group's default rendition, else one the player would pick
    /// on its own, else the first. Nil when the group has none with its own playlist (the sound is in the variant).
    public static func audio(for variant: Variant, in renditions: [Rendition]) -> Rendition? {
        guard let group = variant.audioGroup else { return nil }
        let candidates = renditions.filter { $0.groupId == group && $0.uri != nil }
        return candidates.first(where: \.isDefault) ?? candidates.first(where: \.autoselect) ?? candidates.first
    }

    /// `<length>[@<offset>]`.
    static func byteRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard let length = Int64(parts.first ?? ""), length > 0 else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
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
