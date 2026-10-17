import KomizoCore
import SwiftUI

@main
struct KomizoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(delegate.model)
                .environment(delegate.windows)
                .environment(delegate.updates)
        } label: {
            MenuBarIcon(engine: delegate.model.engine, windows: delegate.windows)
        }
        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.windows)
                .environment(delegate.updates)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var windows = WindowManager(model: model)
    let updates = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests run inside the app; they build what they need themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        model.onPending = { [weak self] in self?.windows.showCatchPanel() }
        model.start()
        updates.start()
        #if DEBUG
        if let target = UserDefaults.standard.string(forKey: "KomizoShow") {
            windows.showForDebugging(target)
            return
        }
        #endif
        windows.showMain()
    }

    /// The window closes but the app keeps running for the browser extension.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showMain()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flush()
    }
}

/// The menu bar icon is the app icon itself, in colour, as TickThock's and PortGlimpse's are: the dark tile with the
/// segmented arrow. While anything downloads, the shaft's four segments fill from the top with the combined progress.
struct MenuBarIcon: View {
    let engine: DownloadEngine
    let windows: WindowManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let combined = engine.combined
        Image(nsImage: MenuBarGlyph.make(fraction: combined.fraction))
            .accessibilityLabel(combined.fraction.map { "Komizo, \(Format.percent($0)) downloaded" } ?? "Komizo")
            // The icon lives as long as the app, so it lends the window manager SwiftUI's way to open Settings.
            .onAppear { windows.openSettings = openSettings }
    }
}

@MainActor
enum MenuBarGlyph {
    /// Menu bar icons are 18 points tall; the app icon's tile fills that once its transparent margin is cropped.
    /// Drawn on demand from the icon itself, as TickThock does, so it is the icon and stays sharp at any scale.
    static func make(fraction: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let icon = NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: size, flipped: false) { rect in
            // The icon's squircle spans 100...924 of its 1024-point canvas.
            let tile = NSRect(x: icon.size.width * 100 / 1024, y: icon.size.height * 100 / 1024,
                              width: icon.size.width * 824 / 1024, height: icon.size.height * 824 / 1024)
            icon.draw(in: rect, from: tile, operation: .sourceOver, fraction: 1)
            if let fraction {
                // Progress: a thin bar along the tile's bottom edge, inside its rounded corner.
                let track = NSRect(x: 4, y: 1.5, width: rect.width - 8, height: 1.5)
                NSColor.white.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: track, xRadius: 0.75, yRadius: 0.75).fill()
                var done = track
                done.size.width = max(1.5, track.width * CGFloat(min(1, max(0, fraction))))
                NSColor(srgbRed: 0x10 / 255, green: 0x98 / 255, blue: 0xF4 / 255, alpha: 1).setFill()
                NSBezierPath(roundedRect: done, xRadius: 0.75, yRadius: 0.75).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
