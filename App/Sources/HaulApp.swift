import HaulCore
import SwiftUI

@main
struct HaulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(delegate.model)
                .environment(delegate.windows)
        } label: {
            MenuBarIcon(engine: delegate.model.engine)
        }
        Settings {
            SettingsView()
                .environment(delegate.model)
                .environment(delegate.windows)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var windows = WindowManager(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests run inside the app; they build what they need themselves.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        model.onPending = { [weak self] in self?.windows.showCatchPanel() }
        model.start()
        #if DEBUG
        if let target = UserDefaults.standard.string(forKey: "HaulShow") {
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

/// The menu bar glyph: a ring that fills with the combined progress while anything downloads, an arrow otherwise.
struct MenuBarIcon: View {
    let engine: DownloadEngine

    var body: some View {
        let combined = engine.combined
        if let fraction = combined.fraction {
            Image(nsImage: RingImage.make(fraction: fraction))
                .accessibilityLabel("Haul, \(Format.percent(fraction)) downloaded")
        } else {
            Image(systemName: "arrow.down.circle").accessibilityLabel("Haul")
        }
    }
}

enum RingImage {
    /// A 18-point template image: a thin track with the completed arc on top and a small arrow in the middle.
    static func make(fraction: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - 1.5
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: center.x, y: center.y + 4))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 4))
            arrow.move(to: NSPoint(x: center.x - 3, y: center.y - 1))
            arrow.line(to: NSPoint(x: center.x, y: center.y - 4))
            arrow.line(to: NSPoint(x: center.x + 3, y: center.y - 1))
            arrow.lineWidth = 1.5
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
