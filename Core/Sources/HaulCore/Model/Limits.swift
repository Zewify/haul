/// How far the engine goes. Haul is free; these are the engine's own ceilings, not a paywall.
public enum Limits {
    /// Connections per download.
    public static let maxConnections = 32
    /// Downloads running at once.
    public static let maxConcurrent = 8

    public static func clampConnections(_ n: Int) -> Int { min(max(n, 1), maxConnections) }
    public static func clampConcurrent(_ n: Int) -> Int { min(max(n, 1), maxConcurrent) }
}
