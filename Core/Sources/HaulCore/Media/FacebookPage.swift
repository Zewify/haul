import Foundation

/// Reads the DASH representation table Facebook embeds in a video page, so a pasted reel link can be downloaded
/// (video and audio tracks, joined by `DashTask`) without the browser. Mirrors `Extension/lib/media.js`.
public enum FacebookPage {
    public struct Pair: Sendable, Hashable {
        public var videoId: String
        public var videoURL: URL
        public var audioURL: URL
        public var codec: String
        public var width: Int
        public var height: Int
        public var duration: Double?
    }

    static let key = "\"all_video_dash_prefetch_representations\":"

    public static func isFacebook(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "fb.watch"
    }

    /// The video a Facebook URL is about: /reel/<id>, /watch/?v=<id>, /videos/<id>/.
    public static func videoId(in url: URL) -> String? {
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty, v.allSatisfy(\.isNumber) { return v }
        let parts = url.pathComponents
        for (index, part) in parts.enumerated() where ["reel", "reels", "videos"].contains(part) && index + 1 < parts.count {
            let candidate = parts[index + 1]
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) { return candidate }
        }
        return nil
    }

    /// One pair per codec family per video, H.264 first, in the order the page lists the videos.
    public static func dashPairs(in html: String) -> [Pair] {
        struct Track { var url: URL; var codecs: String; var width: Int; var height: Int; var bandwidth: Int }
        var videos: [String: (video: [Track], audio: [Track], duration: Double?)] = [:]
        var order: [String] = []
        var searchFrom = html.startIndex
        while let range = html.range(of: key, range: searchFrom..<html.endIndex) {
            searchFrom = range.upperBound
            guard let arrayText = balancedArray(in: html, from: range.upperBound),
                  let sets = try? JSONSerialization.jsonObject(with: Data(arrayText.utf8)) as? [[String: Any]] else { continue }
            for set in sets {
                for rep in set["representations"] as? [[String: Any]] ?? [] {
                    guard let base = rep["base_url"] as? String, let mime = rep["mime_type"] as? String,
                          let url = URL(string: base.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0025", with: "%")),
                          let (videoId, duration) = decodeEfg(url) else { continue }
                    let track = Track(url: url, codecs: rep["codecs"] as? String ?? "", width: rep["width"] as? Int ?? 0,
                                      height: rep["height"] as? Int ?? 0, bandwidth: rep["bandwidth"] as? Int ?? 0)
                    if videos[videoId] == nil { videos[videoId] = ([], [], duration); order.append(videoId) }
                    if mime.hasPrefix("audio/") { videos[videoId]!.audio.append(track) } else { videos[videoId]!.video.append(track) }
                }
            }
        }
        var pairs: [Pair] = []
        for videoId in order {
            guard let entry = videos[videoId], let audio = entry.audio.max(by: { $0.bandwidth < $1.bandwidth }), !entry.video.isEmpty else { continue }
            var best: [String: (Track, Int)] = [:]   // family name → best track, family rank
            for track in entry.video {
                guard let family = codecFamily(track.codecs) else { continue }
                if let current = best[family.name]?.0, current.height > track.height || (current.height == track.height && current.bandwidth >= track.bandwidth) { continue }
                best[family.name] = (track, family.rank)
            }
            for (name, (track, _)) in best.sorted(by: { $0.value.1 > $1.value.1 }) {
                pairs.append(Pair(videoId: videoId, videoURL: track.url, audioURL: audio.url, codec: name, width: track.width, height: track.height, duration: entry.duration))
            }
        }
        return pairs
    }

    /// The pair for the video the URL names; a URL without an id (a share link) means the page's first video.
    /// A URL whose id the page does not offer gets nothing, never a neighbouring video.
    public static func pair(for url: URL, among pairs: [Pair]) -> Pair? {
        guard let id = videoId(in: url) else { return pairs.first }
        return pairs.first(where: { $0.videoId == id })
    }

    /// Facebook's progressive files, which it offers to Safari: an H.264 720p "HD" and an SD, listed per video right
    /// after that video's manifest URL (`dash_mpd_debug.mpd?v=<id>`), which is how they are told apart.
    public struct NativePair: Sendable, Hashable {
        public var videoId: String
        public var hdURL: URL?
        public var sdURL: URL?
        public var duration: Double?
        public var hdTag: String?
        public var hdIsH264: Bool { (hdTag ?? "").lowercased().contains("h264") }
    }

    public static func nativePairs(in html: String) -> [NativePair] {
        struct Event { var position: String.Index; var kind: String; var value: String }
        var events: [Event] = []
        for (kind, pattern) in [("manifest", #""dash_manifest_url":"[^"]*?v=(\d+)"#), ("sd", #""browser_native_sd_url":"([^"]+)""#), ("hd", #""browser_native_hd_url":"([^"]+)""#)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let whole = Range(match.range, in: html), let valueRange = Range(match.range(at: 1), in: html) else { continue }
                events.append(Event(position: whole.lowerBound, kind: kind, value: String(html[valueRange])))
            }
        }
        events.sort { $0.position < $1.position }
        var pairs: [NativePair] = []
        var current: NativePair?
        for event in events {
            switch event.kind {
            case "manifest":
                if let done = current { pairs.append(done) }
                current = NativePair(videoId: event.value)
            case "sd", "hd":
                guard current != nil, let url = URL(string: event.value.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0025", with: "%")) else { continue }
                let (tag, duration) = decodeEfgTag(url)
                if event.kind == "hd" { current!.hdURL = url; current!.hdTag = tag } else { current!.sdURL = url }
                if current!.duration == nil { current!.duration = duration }
            default: break
            }
        }
        if let done = current { pairs.append(done) }
        return pairs.filter { $0.hdURL != nil || $0.sdURL != nil }
    }

    static func decodeEfgTag(_ url: URL) -> (String?, Double?) {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "efg" })?.value,
              let data = Base64URL.decode(raw.replacingOccurrences(of: "%3D", with: "").replacingOccurrences(of: "=", with: "")),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil) }
        var tag: String?
        if let r = text.range(of: #""vencode_tag":"[^"]*""#, options: .regularExpression) {
            tag = String(text[r]).replacingOccurrences(of: "\"vencode_tag\":", with: "").replacingOccurrences(of: "\"", with: "")
        }
        var duration: Double?
        if let d = text.range(of: #""duration_s":\s*"?(\d+(\.\d+)?)"#, options: .regularExpression) {
            duration = Double(String(text[d]).filter { $0.isNumber || $0 == "." })
        }
        return (tag, duration)
    }

    static func codecFamily(_ codecs: String) -> (name: String, rank: Int)? {
        let c = codecs.lowercased()
        if c.hasPrefix("avc1") || c.hasPrefix("avc3") { return ("H.264", 3) }
        if c.hasPrefix("hvc1") || c.hasPrefix("hev1") { return ("HEVC", 2) }
        if c.hasPrefix("av01") { return ("AV1", 1) }
        return nil
    }

    /// The `efg` query parameter is base64 JSON naming the video and its length; the id is read as text because it
    /// exceeds what a double can hold exactly.
    static func decodeEfg(_ url: URL) -> (String, Double?)? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "efg" })?.value,
              let data = Base64URL.decode(raw.replacingOccurrences(of: "%3D", with: "").replacingOccurrences(of: "=", with: "")),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let idRange = text.range(of: #""video_id":\s*"?(\d+)"#, options: .regularExpression) else { return nil }
        let id = String(text[idRange]).filter(\.isNumber)
        var duration: Double?
        if let d = text.range(of: #""duration_s":\s*"?(\d+(\.\d+)?)"#, options: .regularExpression) {
            duration = Double(String(text[d]).filter { $0.isNumber || $0 == "." })
        }
        return (id, duration)
    }

    /// The JSON array starting at `start` (its opening bracket), tracking strings so brackets in URLs do not count.
    static func balancedArray(in text: String, from start: String.Index) -> String? {
        var depth = 0, inString = false, escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

extension FacebookPage {
    /// The download a pasted Facebook video link should become: the page's video and audio tracks as one DASH
    /// download, named after the page and the video's id. nil when the page shows no video (a login wall, a deleted post).
    public static func download(for pageURL: URL, html: String, folder: URL) -> Download? {
        let title = pageTitle(in: html) ?? "Facebook"
        let context = RequestContext(referrer: pageURL.absoluteString)
        // The progressive H.264 file first: it plays everywhere. Its SD sibling lends its sound if the HD one has none.
        let natives = nativePairs(in: html)
        let native: NativePair? = videoId(in: pageURL).map { id in natives.first { $0.videoId == id } } ?? natives.first
        if let native, let hd = native.hdURL ?? native.sdURL {
            let name = Filename.mediaName(pageTitle: title, url: hd, contentType: "video/mp4", videoId: native.videoId)
            var download = Download(url: hd, kind: .dash, name: name, folder: folder, context: context)
            download.audioURL = native.sdURL ?? hd
            download.media = true
            return download
        }
        guard let pair = pair(for: pageURL, among: dashPairs(in: html)) else { return nil }
        let name = Filename.mediaName(pageTitle: title, url: pair.videoURL, contentType: "video/mp4", videoId: pair.videoId)
        var download = Download(url: pair.videoURL, kind: .dash, name: name, folder: folder, context: context)
        download.audioURL = pair.audioURL
        download.media = true
        return download
    }
}

extension FacebookPage {
    /// The page's <title>, or nil when it has none or it is empty.
    static func pageTitle(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex),
              let start = html.range(of: ">", range: open.upperBound..<close.lowerBound) else { return nil }
        let title = html[start.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
