import AppKit
import DownhaulCore
import Observation

/// Once a day, asks GitHub for Downhaul's latest release and remembers a newer one, as PortGlimpse does.
/// Downhaul is installed by the curl command, so an update is that command again; network failures are silent.
@MainActor
@Observable
final class UpdateChecker {
    nonisolated static let installCommand = "curl -fsSL https://zewify.com/downhaul/install.sh | sh"
    nonisolated static let feed = URL(string: "https://api.github.com/repos/Zewify/downhaul/releases/latest")!

    private enum Keys {
        static let enabled = "checkForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let latestKnown = "latestKnownVersion"
    }

    private(set) var available: AppVersion?
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                remember(defaults.string(forKey: Keys.latestKnown).flatMap(AppVersion.init))
                Task { await check(force: true) }
            } else {
                available = nil
            }
        }
    }

    private let defaults: UserDefaults
    private let current: AppVersion?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(defaults: UserDefaults = .standard,
         current: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.current = current.flatMap(AppVersion.init)
        self.fetch = fetch
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        remember(defaults.string(forKey: Keys.latestKnown).flatMap(AppVersion.init))
    }

    func start() {
        Task {
            while !Task.isCancelled {
                await check(force: false)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check(force: Bool) async {
        guard isEnabled else { return }
        let last = defaults.object(forKey: Keys.lastCheck) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= 86_400 else { return }
        var request = URLRequest(url: Self.feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Only a request that got an HTTP response uses up the day; offline or timeout retries on the next pass.
        guard let (data, response) = try? await fetch(request), let http = response as? HTTPURLResponse else { return }
        defaults.set(Date(), forKey: Keys.lastCheck)
        guard http.statusCode == 200, let latest = try? ReleaseFeed.latestVersion(fromJSON: data) else { return }
        defaults.set(latest.description, forKey: Keys.latestKnown)
        remember(latest)
    }

    private func remember(_ latest: AppVersion?) {
        guard isEnabled, let latest, let current, latest > current else { available = nil; return }
        available = latest
    }

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
    }
}
