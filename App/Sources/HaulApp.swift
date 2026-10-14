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

/// The menu bar icon is the app icon itself, in colour, as TickThock's and PortGlimpse's are: the dark tile with the
/// segmented arrow. While anything downloads, the shaft's four segments fill from the top with the combined progress.
struct MenuBarIcon: View {
    let engine: DownloadEngine

    var body: some View {
        let combined = engine.combined
        Image(nsImage: MenuBarGlyph.make(fraction: combined.fraction))
            .accessibilityLabel(combined.fraction.map { "Haul, \(Format.percent($0)) downloaded" } ?? "Haul")
    }
}

enum MenuBarGlyph {
    /// Menu bar icons are 18 points tall. Drawn on demand, so it stays sharp at whatever scale the display uses.
    static func make(fraction: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor(srgbRed: 0x1E / 255, green: 0x1B / 255, blue: 0x22 / 255, alpha: 1).setFill()
            tile.fill()
            let blue = NSColor(srgbRed: 0x10 / 255, green: 0x98 / 255, blue: 0xF4 / 255, alpha: 1)
            let lit = fraction.map { max(1, Int(($0 * 4).rounded(.up))) } ?? 4
            // The shaft: four segments from the top, in the icon's proportions.
            let width: CGFloat = 3.2, height: CGFloat = 1.6, gap: CGFloat = 0.6, x: CGFloat = 9 - 1.6
            for index in 0..<4 {
                let y = 15.3 - CGFloat(index) * (height + gap)
                blue.withAlphaComponent(index < lit ? 1 : 0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 0.5, yRadius: 0.5).fill()
            }
            // The arrowhead below it.
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 4.6, y: 8.1))
            head.line(to: NSPoint(x: 13.4, y: 8.1))
            head.line(to: NSPoint(x: 9, y: 3.4))
            head.close()
            head.lineJoinStyle = .round
            head.lineWidth = 0.9
            blue.setFill()
            blue.setStroke()
            head.fill()
            head.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
