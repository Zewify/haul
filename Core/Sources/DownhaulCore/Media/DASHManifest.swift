import Foundation

/// Enough of MPEG-DASH (ISO/IEC 23009-1) to download a finished video from any site that streams it: the best video
/// representation a Mac can play and the best audio, as `SegmentTemplate` (numbered or timed, with or without a
/// timeline), `SegmentList`, or one whole file per representation (`SegmentBase`, or a bare `BaseURL`).
public enum DASHManifest {
    public enum ParseError: Error, Equatable {
        case notAManifest
        /// `ContentProtection` on every representation worth taking: Widevine, PlayReady, FairPlay, ClearKey.
        case drm
        /// `type="dynamic"`: a live stream has no end to download to.
        case live
        case noPlayableVideo
        case unsupported(String)

        public var message: String {
            switch self {
            case .notAManifest: "Not a DASH manifest."
            case .drm: "This video is protected (DRM) and cannot be saved."
            case .live: "This is a live stream; Downhaul saves finished videos."
            case .noPlayableVideo: "This stream has no video format a Mac can play."
            case .unsupported(let what): "This stream uses \(what), which Downhaul cannot read yet."
            }
        }
    }

    public static func plan(_ xml: Data, base: URL) throws -> StreamPlan {
        guard let root = Node.parse(xml), root.name == "MPD" else { throw ParseError.notAManifest }
        if root["type"] == "dynamic" { throw ParseError.live }
        let total = root["mediaPresentationDuration"].flatMap(duration)
        let mpdBase = resolve(root, against: base)
        guard let (period, periodDuration) = longestPeriod(root, total: total) else { throw ParseError.notAManifest }
        let periodBase = resolve(period, against: mpdBase)

        var videos: [Candidate] = [], audios: [Candidate] = []
        var sawProtectedVideo = false
        for set in period.children("AdaptationSet") {
            let setProtected = !set.children("ContentProtection").isEmpty
            for rep in set.children("Representation") {
                let mime = rep["mimeType"] ?? set["mimeType"] ?? ""
                let codecs = (rep["codecs"] ?? set["codecs"] ?? "").lowercased()
                let type = set["contentType"] ?? set.children("ContentComponent").first?["contentType"] ?? String(mime.split(separator: "/").first ?? "")
                let protected = setProtected || !rep.children("ContentProtection").isEmpty
                let bandwidth = Int(rep["bandwidth"] ?? "") ?? 0
                if type == "video" {
                    guard mime.isEmpty || mime == "video/mp4", let rank = videoRank(codecs) else { continue }
                    if protected { sawProtectedVideo = true; continue }
                    videos.append(Candidate(set: set, rep: rep, bandwidth: bandwidth, height: Int(rep["height"] ?? set["height"] ?? "") ?? 0, rank: rank, main: false))
                } else if type == "audio" {
                    guard !protected, mime.isEmpty || mime == "audio/mp4", ["mp4a", "ac-3", "ec-3"].contains(where: codecs.hasPrefix) else { continue }
                    audios.append(Candidate(set: set, rep: rep, bandwidth: bandwidth, height: 0, rank: 0, main: set.children("Role").contains { $0["value"] == "main" }))
                }
            }
        }
        // H.264 plays on every Mac, so it wins over a taller HEVC or AV1 stream; within a family, the tallest, then the richest.
        guard let video = videos.max(by: { ($0.rank, $0.height, $0.bandwidth) < ($1.rank, $1.height, $1.bandwidth) }) else {
            throw sawProtectedVideo ? ParseError.drm : ParseError.noPlayableVideo
        }
        let audio = audios.max { ($0.main ? 1 : 0, $0.bandwidth) < ($1.main ? 1 : 0, $1.bandwidth) }
        return StreamPlan(video: try track(video, period: period, base: periodBase, periodDuration: periodDuration),
                          audio: try audio.map { try track($0, period: period, base: periodBase, periodDuration: periodDuration) })
    }

    private struct Candidate {
        var set: Node
        var rep: Node
        var bandwidth: Int
        var height: Int
        var rank: Int
        var main: Bool
    }

    private static func videoRank(_ codecs: String) -> Int? {
        if codecs.hasPrefix("avc1") || codecs.hasPrefix("avc3") { return 3 }
        if codecs.hasPrefix("hvc1") || codecs.hasPrefix("hev1") { return 2 }
        if codecs.hasPrefix("av01") { return 1 }
        return nil   // VP9 and the rest cannot go into an MP4 a Mac will play
    }

    /// The period that is the programme, not an ad or a slate around it: the longest.
    private static func longestPeriod(_ root: Node, total: Double?) -> (Node, Double?)? {
        let periods = root.children("Period")
        var best: (Node, Double?)?
        for (index, period) in periods.enumerated() {
            let start = period["start"].flatMap(duration) ?? 0
            let nextStart = index + 1 < periods.count ? periods[index + 1]["start"].flatMap(duration) : nil
            let length = period["duration"].flatMap(duration) ?? nextStart.map { $0 - start } ?? total.map { $0 - start }
            if best == nil || (length ?? 0) > (best!.1 ?? 0) { best = (period, length) }
        }
        return best
    }

    private static func track(_ candidate: Candidate, period: Node, base: URL, periodDuration: Double?) throws -> StreamTrack {
        let setBase = resolve(candidate.set, against: base)
        let repBase = resolve(candidate.rep, against: setBase)
        let id = candidate.rep["id"] ?? ""
        let bandwidth = candidate.rep["bandwidth"] ?? ""
        let levels = [period, candidate.set, candidate.rep]

        let templates = levels.compactMap { $0.children("SegmentTemplate").first }
        if !templates.isEmpty {
            // The nearest level's attributes win; the nearest timeline is the one that applies.
            var attrs: [String: String] = [:]
            for template in templates { attrs.merge(template.attributes) { $1 } }
            let timeline = templates.last { !$0.children("SegmentTimeline").isEmpty }?.children("SegmentTimeline").first
            let initialization = attrs["initialization"] ?? templates.last { !$0.children("Initialization").isEmpty }?.children("Initialization").first?["sourceURL"]
            guard let media = attrs["media"] else { throw ParseError.unsupported("a segment template with no media") }
            let timescale = Double(attrs["timescale"] ?? "") ?? 1
            let startNumber = Int(attrs["startNumber"] ?? "") ?? 1
            var segments: [StreamSegment] = []
            func add(number: Int, time: Int64, length: Int64) {
                let path = substitute(media, id: id, bandwidth: bandwidth, number: number, time: time)
                if let url = URL(string: path, relativeTo: repBase)?.absoluteURL {
                    segments.append(StreamSegment(uri: url, duration: Double(length) / timescale, sequence: number))
                }
            }
            if let timeline {
                var time: Int64 = 0, number = startNumber
                let end = periodDuration.map { Int64(($0 * timescale).rounded()) }
                for s in timeline.children("S") {
                    guard let d = Int64(s["d"] ?? ""), d > 0 else { continue }
                    if let t = Int64(s["t"] ?? "") { time = t }
                    var repeats = Int(s["r"] ?? "") ?? 0
                    if repeats < 0 {
                        // r = -1 repeats until the period ends.
                        guard let end else { throw ParseError.unsupported("an open-ended timeline") }
                        repeats = max(0, Int((Double(end - time) / Double(d)).rounded(.up)) - 1)
                    }
                    for _ in 0...repeats {
                        add(number: number, time: time, length: d)
                        time += d
                        number += 1
                    }
                }
            } else {
                guard let length = Int64(attrs["duration"] ?? ""), length > 0 else { throw ParseError.unsupported("a segment template with no duration") }
                guard let periodDuration else { throw ParseError.unsupported("a stream with no length") }
                let count = Int((periodDuration * timescale / Double(length)).rounded(.up))
                for index in 0..<count { add(number: startNumber + index, time: Int64(index) * length, length: length) }
            }
            guard !segments.isEmpty else { throw ParseError.unsupported("an empty segment template") }
            let map = initialization.flatMap { URL(string: substitute($0, id: id, bandwidth: bandwidth, number: startNumber, time: 0), relativeTo: repBase)?.absoluteURL }
            return StreamTrack(segments: segments, map: map.map { StreamSegment(uri: $0) })
        }

        if let list = levels.compactMap({ $0.children("SegmentList").first }).last {
            let timescale = Double(list["timescale"] ?? "") ?? 1
            let length = Double(list["duration"] ?? "") ?? 0
            var segments: [StreamSegment] = []
            for (index, url) in list.children("SegmentURL").enumerated() {
                let uri = url["media"].flatMap { URL(string: $0, relativeTo: repBase)?.absoluteURL } ?? repBase
                segments.append(StreamSegment(uri: uri, range: url["mediaRange"].flatMap(range), duration: length / timescale, sequence: index))
            }
            guard !segments.isEmpty else { throw ParseError.unsupported("an empty segment list") }
            let map = list.children("Initialization").first.map { initialization in
                StreamSegment(uri: initialization["sourceURL"].flatMap { URL(string: $0, relativeTo: repBase)?.absoluteURL } ?? repBase,
                              range: initialization["range"].flatMap(range))
            }
            return StreamTrack(segments: segments, map: map)
        }

        // SegmentBase, or nothing at all: the representation is one file.
        return StreamTrack(segments: [StreamSegment(uri: repBase, duration: periodDuration ?? 0)])
    }

    /// A node's own `BaseURL`, resolved against its parent's.
    private static func resolve(_ node: Node, against base: URL) -> URL {
        guard let text = node.children("BaseURL").first?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text, relativeTo: base)?.absoluteURL else { return base }
        return url
    }

    /// `$RepresentationID$`, `$Bandwidth$`, `$Number$` and `$Time$`, each optionally `%0<width>d`; `$$` is a dollar.
    static func substitute(_ template: String, id: String, bandwidth: String, number: Int, time: Int64) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "$") {
            out += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "$") else { out += rest[open...]; return out }
            let token = rest[after..<close]
            let parts = token.split(separator: "%", maxSplits: 1)
            let name = parts.first.map(String.init) ?? ""
            let width = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "0d"))) ?? 0 : 0
            func padded(_ value: String) -> String { String(repeating: "0", count: max(0, width - value.count)) + value }
            switch name {
            case "": out += "$"
            case "RepresentationID": out += id
            case "Bandwidth": out += padded(bandwidth)
            case "Number": out += padded(String(number))
            case "Time": out += padded(String(time))
            default: out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// `first-last`, inclusive.
    static func range(_ text: String) -> ClosedRange<Int64>? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]), end >= start else { return nil }
        return start...end
    }

    /// An ISO 8601 duration as DASH writes them: `PT1H2M3.5S`, `P1DT2H`.
    static func duration(_ text: String) -> Double? {
        guard text.hasPrefix("P") else { return nil }
        var seconds = 0.0, number = "", inTime = false
        for character in text.dropFirst() {
            switch character {
            case "T": inTime = true
            case "0"..."9", ".": number.append(character)
            default:
                guard let value = Double(number) else { return nil }
                number = ""
                switch (character, inTime) {
                case ("D", false): seconds += value * 86400
                case ("H", true): seconds += value * 3600
                case ("M", true): seconds += value * 60
                case ("S", true): seconds += value
                default: return nil
                }
            }
        }
        return number.isEmpty ? seconds : nil
    }

    /// The manifest as a tree of elements, names without their namespace prefix.
    final class Node {
        let name: String
        let attributes: [String: String]
        var elements: [Node] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        subscript(attribute: String) -> String? { attributes[attribute] }
        func children(_ name: String) -> [Node] { elements.filter { $0.name == name } }

        static func parse(_ data: Data) -> Node? {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = builder
            guard parser.parse() else { return nil }
            return builder.root
        }

        private final class Builder: NSObject, XMLParserDelegate {
            var root: Node?
            var stack: [Node] = []

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
                let node = Node(name: elementName, attributes: attributes)
                if let parent = stack.last { parent.elements.append(node) } else { root = node }
                stack.append(node)
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
                stack.removeLast()
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                stack.last?.text += string
            }
        }
    }
}
