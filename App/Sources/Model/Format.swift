import Foundation

/// Human numbers for the list: sizes, speeds, times left.
enum Format {
    private static var style: ByteCountFormatStyle {
        .byteCount(style: .file, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false)
    }

    static func size(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(style)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return Int64(bytesPerSecond).formatted(style) + "/s"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return "\(Int((fraction * 100).rounded(.down)))%"
    }
}
