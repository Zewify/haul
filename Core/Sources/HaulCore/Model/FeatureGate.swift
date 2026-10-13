/// Which build this is. The store edition ships on the Mac App Store; the direct edition is sold from zewify.com
/// and is the only one with the video grabber, because Apple rejects apps that download from video sites.
public enum Edition: String, Codable, Sendable {
    case store, direct
}

/// Every free/Pro rule in the product. UI locks ask `allows(_:)`; the engine asks for the clamped limits.
public struct FeatureGate: Sendable, Hashable {
    public enum Feature: Sendable {
        case mediaGrabber, speedLimiter, scheduler
    }

    public let edition: Edition
    public let isPro: Bool

    public init(edition: Edition, isPro: Bool) {
        self.edition = edition
        self.isPro = isPro
    }

    /// Connections per download: 4 free, 32 Pro.
    public var maxConnections: Int { isPro ? 32 : 4 }
    /// Downloads running at once: 2 free, 8 Pro.
    public var maxConcurrent: Int { isPro ? 8 : 2 }

    /// Whether this edition has the grabber at all, Pro or not; decides whether the UI and extension show it.
    public var offersMedia: Bool { edition == .direct }

    public func allows(_ feature: Feature) -> Bool {
        guard isPro else { return false }
        switch feature {
        case .mediaGrabber: return offersMedia
        case .speedLimiter, .scheduler: return true
        }
    }

    public func clampConnections(_ n: Int) -> Int { min(max(n, 1), maxConnections) }
    public func clampConcurrent(_ n: Int) -> Int { min(max(n, 1), maxConcurrent) }
}
