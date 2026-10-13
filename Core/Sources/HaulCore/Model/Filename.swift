import Foundation

/// Where a download's name comes from and what it may look like on disk.
public enum Filename {
    public static let fallback = "download"
    public static let partExtension = "haulpart"

    /// The name a `Content-Disposition` header asks for: `filename*=` (RFC 5987) wins over `filename=`.
    public static func fromContentDisposition(_ header: String) -> String? {
        var plain: String?
        var extended: String?
        for part in header.split(separator: ";").dropFirst() {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // charset'language'percent-encoded
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                guard pieces.count == 3 else { continue }
                extended = String(pieces[2]).removingPercentEncoding
            } else if key == "filename" {
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                plain = value
            }
        }
        let chosen = (extended ?? plain)?.trimmingCharacters(in: .whitespaces)
        guard let chosen, !chosen.isEmpty else { return nil }
        return chosen
    }

    /// The last path component of the URL, percent-decoded; `download` when there is none.
    public static func fromURL(_ url: URL) -> String {
        let component = url.lastPathComponent
        guard !component.isEmpty, component != "/" else { return fallback }
        return component.removingPercentEncoding ?? component
    }

    /// A name that stays inside its folder: the last path component after either separator, no control
    /// characters, no colons, no leading dots, no more than 255 bytes, and never empty.
    public static func sanitised(_ name: String) -> String {
        let lastComponent = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = ""
        for scalar in lastComponent.unicodeScalars {
            if scalar == ":" { cleaned.unicodeScalars.append("_") }
            else if scalar.value >= 0x20 && scalar.value != 0x7F { cleaned.unicodeScalars.append(scalar) }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return fallback }
        return truncated(cleaned, toBytes: 255)
    }

    /// Shortens the stem, never the extension, until the name fits.
    private static func truncated(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : "." + ext
        while (stem + suffix).utf8.count > limit, !stem.isEmpty { stem.removeLast() }
        return stem.isEmpty ? fallback : stem + suffix
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… — the first that neither exists nor has a part file in progress.
    /// `ignoring` names files that do not count, such as a download's own part file.
    public static func available(_ name: String, in folder: URL, ignoring: Set<String> = [], fileManager: FileManager = .default) -> String {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var candidate = name
        var counter = 2
        while isTaken(candidate, in: folder, ignoring: ignoring, fileManager: fileManager) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    public static func partName(for name: String) -> String { name + "." + partExtension }

    /// A name for a video grabbed from a page: the page's title (minus a " | Site" suffix) with the file's extension,
    /// because CDN names are hashes; the URL's own name when there is no title.
    public static func mediaName(pageTitle: String?, url: URL, contentType: String?) -> String {
        let urlName = sanitised(fromURL(url))
        let ext = fileExtension(for: contentType) ?? (url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased())
        var title = (pageTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            if let ext, (urlName as NSString).pathExtension.lowercased() != ext { return urlName + "." + ext }
            return urlName
        }
        title = title.replacingOccurrences(of: " | ", with: " - ").replacingOccurrences(of: " – ", with: " - ")
        let base = sanitised(title)
        guard let ext, ext != "m3u8" else { return base }
        return base.lowercased().hasSuffix("." + ext) ? base : base + "." + ext
    }

    static func fileExtension(for contentType: String?) -> String? {
        switch contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "video/mp4", "video/x-m4v": "mp4"
        case "video/webm": "webm"
        case "video/quicktime": "mov"
        case "video/x-matroska": "mkv"
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/ogg": "ogg"
        case "audio/wav", "audio/x-wav": "wav"
        default: nil
        }
    }

    private static func isTaken(_ name: String, in folder: URL, ignoring: Set<String>, fileManager: FileManager) -> Bool {
        for candidate in [name, partName(for: name)] where !ignoring.contains(candidate) {
            if fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return true }
        }
        return false
    }
}
