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

/// The menu bar glyph is the app icon's mark: the segmented shaft and the arrowhead, as a template image.
/// While anything downloads, the shaft's four segments fill from the top with the combined progress.
struct MenuBarIcon: View {
    let engine: DownloadEngine

    var body: some View {
        let combined = engine.combined
        Image(nsImage: MenuBarGlyph.make(fraction: combined.fraction))
            .accessibilityLabel(combined.fraction.map { "Haul, \(Format.percent($0)) downloaded" } ?? "Haul")
    }
}

enum MenuBarGlyph {
    /// An 18-point template image. With a fraction, segments past the progress are drawn faint.
    static func make(fraction: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let lit = fraction.map { max(1, Int(($0 * 4).rounded(.up))) } ?? 4
            // The shaft: four segments stacked from the top, the same proportions as the app icon.
            let width: CGFloat = 5, height: CGFloat = 2, gap: CGFloat = 0.75, x: CGFloat = 6.5
            for index in 0..<4 {
                let y = 15.25 - CGFloat(index) * (height + gap)
                let segment = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 0.6, yRadius: 0.6)
                NSColor.black.withAlphaComponent(index < lit ? 1 : 0.3).setFill()
                segment.fill()
            }
            // The arrowhead below it.
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 3, y: 6.5))
            head.line(to: NSPoint(x: 15, y: 6.5))
            head.line(to: NSPoint(x: 9, y: 0.75))
            head.close()
            head.lineJoinStyle = .round
            head.lineWidth = 1.2
            NSColor.black.setFill()
            NSColor.black.setStroke()
            head.fill()
            head.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
