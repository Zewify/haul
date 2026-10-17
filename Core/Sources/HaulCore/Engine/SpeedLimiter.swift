import Foundation

/// A cap on how fast all downloads together may go, shared by every connection of every download.
///
/// A token bucket that may run into debt: readers spend the bytes they are about to write in small slices
/// (`spend`), and whoever pushes the bucket below zero waits until the debt is paid. A reader that waits stops
/// draining its `HTTPStream`, whose flow control then suspends the socket, so the network itself runs at the cap.
/// Changing the cap releases everyone waiting at once, so lifting it speeds running downloads up straight away.
public final class SpeedLimiter: @unchecked Sendable {
    /// The smallest cap the app offers; below it a pause can outlast a server's patience with a silent connection.
    public static let minimum: Int64 = 100_000
    /// How much a reader spends and writes at a time: small enough that progress moves and no burst slips through.
    public static let slice = 64 << 10

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var rate: Double?
    private var available: Double = 0
    private var last: TimeInterval
    /// What is waiting out a pause, so a change of cap can release it early.
    private var waiting: [UUID: @Sendable () -> Void] = [:]

    public init(bytesPerSecond: Int64? = nil, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.last = now()
        self.rate = bytesPerSecond.map { Double(max($0, 1)) }
    }

    /// Bytes per second for everything at once; nil is no limit.
    public var bytesPerSecond: Int64? {
        get { lock.withLock { rate.map { Int64($0) } } }
        set {
            let released = lock.withLock {
                rate = newValue.map { Double(max($0, 1)) }
                // A new cap starts from an empty bucket, so turning it on bites at once instead of after a burst.
                available = 0
                last = now()
                defer { waiting.removeAll() }
                return Array(waiting.values)
            }
            for action in released { action() }
        }
    }

    /// Takes `count` bytes off the budget and returns how long the caller should wait, 0 when within the cap.
    public func take(_ count: Int) -> TimeInterval {
        lock.withLock {
            guard let rate else { return 0 }
            let time = now()
            // A quarter of a second of credit at most: enough to keep connections busy, not enough to burst past the cap.
            available = min(rate / 4, available + (time - last) * rate)
            last = time
            available -= Double(count)
            return available >= 0 ? 0 : -available / rate
        }
    }

    /// Spends `count` bytes, waiting until they are affordable, the cap changes, or the task is cancelled.
    public func spend(_ count: Int) async {
        let wait = take(count)
        guard wait > 0, !Task.isCancelled else { return }
        let held = HeldID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let id = hold(for: wait) { continuation.resume() }
                held.value = id
                // A cancel that landed before the hold existed had nothing to release; release it now instead.
                if Task.isCancelled { release(id) }
            }
        } onCancel: {
            if let id = held.value { release(id) }
        }
    }

    /// Runs `action` once `seconds` have passed, or as soon as the cap changes, whichever comes first.
    private func hold(for seconds: TimeInterval, then action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { waiting[id] = action }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.release(id) }
        return id
    }

    private func release(_ id: UUID) {
        let action = lock.withLock { waiting.removeValue(forKey: id) }
        action?()
    }

    private final class HeldID: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: UUID?
        var value: UUID? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }
}
