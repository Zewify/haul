import Foundation

/// What the first bytes of an MP4 say about it, without downloading it: its length and which tracks it carries.
/// Enough to tell which of a page's files is the video being watched, and which video-only and audio-only files
/// belong together. Reads `moov` (`mvhd`, each `trak`'s `tkhd` and `hdlr`, `mvex/mehd`) and, for a fragmented file
/// whose `mvhd` says nothing about length, the `sidx` index that follows it.
public struct MP4Probe: Sendable, Hashable, Codable {
    public var duration: Double?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var width: Int
    public var height: Int

    /// How many bytes to fetch from the start of a file: room for a `moov` and its `sidx` in a streaming-ready file.
    public static let headLength: Int64 = 256 << 10

    /// How many bytes from the start are needed to read the whole `moov`, when `data` cuts it short. A long video's
    /// sample tables run to megabytes, and a track past the cut would otherwise look absent (a "silent" file that is not).
    public static func requiredLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let moov = boxes(bytes, 0, bytes.count, clip: false).first(where: { $0.type == "moov" }), moov.end > bytes.count else { return nil }
        return moov.end
    }

    /// nil when the bytes hold no complete `moov` (not an MP4, one with its index at the end, or cut short: see
    /// `requiredLength`).
    public static func read(_ data: Data) -> MP4Probe? {
        let bytes = [UInt8](data)
        guard requiredLength(data) == nil else { return nil }
        let top = boxes(bytes, 0, bytes.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { return nil }
        var probe = MP4Probe(duration: nil, hasVideo: false, hasAudio: false, width: 0, height: 0)
        for box in boxes(bytes, moov.body, moov.end) {
            switch box.type {
            case "mvhd":
                probe.duration = mvhdDuration(bytes, box)
            case "mvex":
                if probe.duration == nil || probe.duration == 0,
                   let mehd = boxes(bytes, box.body, box.end).first(where: { $0.type == "mehd" }),
                   let timescale = mvhdTimescale(bytes, moov) {
                    let version = bytes[mehd.body]
                    let value = version == 1 ? u64(bytes, mehd.body + 4) : UInt64(u32(bytes, mehd.body + 4))
                    if value > 0 { probe.duration = Double(value) / Double(timescale) }
                }
            case "trak":
                readTrack(bytes, box, into: &probe)
            default:
                break
            }
        }
        if probe.duration == nil || probe.duration == 0, let sidx = top.first(where: { $0.type == "sidx" }) {
            probe.duration = sidxDuration(bytes, sidx)
        }
        if probe.duration == 0 { probe.duration = nil }
        return probe
    }

    struct Box {
        var type: String
        var start: Int
        var body: Int
        var end: Int
    }

    /// The boxes between `from` and `to`; with `clip`, a box running past the bytes we have is cut to what is there.
    static func boxes(_ bytes: [UInt8], _ from: Int, _ to: Int, clip: Bool = true) -> [Box] {
        var result: [Box] = []
        var at = from
        while at + 8 <= to {
            var size = Int(u32(bytes, at))
            let type = String(bytes: bytes[(at + 4)..<(at + 8)], encoding: .ascii) ?? ""
            var header = 8
            if size == 1 {
                guard at + 16 <= to else { break }
                size = Int(clamping: u64(bytes, at + 8))
                header = 16
            } else if size == 0 {
                size = to - at
            }
            guard size >= header else { break }
            result.append(Box(type: type, start: at, body: at + header, end: clip ? min(at + size, to) : at + size))
            at += size
        }
        return result
    }

    private static func readTrack(_ bytes: [UInt8], _ trak: Box, into probe: inout MP4Probe) {
        let children = boxes(bytes, trak.body, trak.end)
        guard let mdia = children.first(where: { $0.type == "mdia" }),
              let hdlr = boxes(bytes, mdia.body, mdia.end).first(where: { $0.type == "hdlr" }), hdlr.body + 12 <= hdlr.end else { return }
        let handler = String(bytes: bytes[(hdlr.body + 8)..<(hdlr.body + 12)], encoding: .ascii)
        if handler == "soun" { probe.hasAudio = true }
        guard handler == "vide" else { return }
        probe.hasVideo = true
        // tkhd ends with width and height as 16.16 fixed point.
        if let tkhd = children.first(where: { $0.type == "tkhd" }), tkhd.end - 8 >= tkhd.body {
            let width = Int(u32(bytes, tkhd.end - 8) >> 16), height = Int(u32(bytes, tkhd.end - 4) >> 16)
            if width * height > probe.width * probe.height { probe.width = width; probe.height = height }
        }
    }

    private static func mvhdTimescale(_ bytes: [UInt8], _ moov: Box) -> UInt32? {
        guard let mvhd = boxes(bytes, moov.body, moov.end).first(where: { $0.type == "mvhd" }) else { return nil }
        return bytes[mvhd.body] == 1 ? u32(bytes, mvhd.body + 20) : u32(bytes, mvhd.body + 12)
    }

    private static func mvhdDuration(_ bytes: [UInt8], _ mvhd: Box) -> Double? {
        let version = bytes[mvhd.body]
        let timescale = version == 1 ? u32(bytes, mvhd.body + 20) : u32(bytes, mvhd.body + 12)
        let duration = version == 1 ? u64(bytes, mvhd.body + 24) : UInt64(u32(bytes, mvhd.body + 16))
        guard timescale > 0, duration != UInt64(UInt32.max), duration != UInt64.max else { return nil }
        return Double(duration) / Double(timescale)
    }

    /// The sum of a segment index's subsegment durations.
    private static func sidxDuration(_ bytes: [UInt8], _ sidx: Box) -> Double? {
        let version = bytes[sidx.body]
        let timescale = u32(bytes, sidx.body + 8)
        var at = sidx.body + 12 + (version == 0 ? 8 : 16) + 2
        guard timescale > 0, at + 2 <= sidx.end else { return nil }
        let count = Int(bytes[at]) << 8 | Int(bytes[at + 1])
        at += 2
        var total: UInt64 = 0
        for _ in 0..<count {
            guard at + 12 <= sidx.end else { break }
            total += UInt64(u32(bytes, at + 4))
            at += 12
        }
        return total > 0 ? Double(total) / Double(timescale) : nil
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32(b, i)) << 32 | UInt64(u32(b, i + 4))
    }
}
