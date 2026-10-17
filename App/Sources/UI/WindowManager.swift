import AppKit
import Observation
import SwiftUI

/// Opens and tracks the app's windows: the main list and the floating catch panel.
@MainActor
@Observable
final class WindowManager {
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var main: NSWindow?
    @ObservationIgnored private var catchPanel: NSPanel?
    /// SwiftUI's Settings opener, lent by the menu bar icon. The old `showSettingsWindow:` action does nothing for a
    /// SwiftUI Settings scene on current macOS, which left the menu's Settings… item dead.
    @ObservationIgnored var openSettings: OpenSettingsAction?

    static let mainFrame = "HaulMain"

    init(model: AppModel) { self.model = model }

    func showMain() {
        let isNew = main == nil
        let window = main ?? makeMain()
        main = window
        if isNew && !window.setFrameUsingName(Self.mainFrame) { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMain() -> NSWindow {
        let host = NSHostingController(rootView: MainWindow().environment(model).environment(self))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Haul"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 480))
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.mainFrame)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        return window
    }

    /// The catch panel floats above everything and shows the oldest pending download; it closes itself when none are left.
    func showCatchPanel() {
        guard !model.pending.isEmpty else { catchPanel?.close(); return }
        if catchPanel == nil {
            let host = NSHostingController(rootView: CatchPanel().environment(model).environment(self))
            host.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: host)
            panel.title = "Download"
            panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.setFrameAutosaveName("HaulCatch")
            catchPanel = panel
        }
        guard let panel = catchPanel else { return }
        if !panel.isVisible, !panel.setFrameUsingName("HaulCatch") {
            // Top right of the main screen, where a browser's own download shelf would appear.
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 24))
            }
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func closeCatchPanelIfIdle() {
        if model.pending.isEmpty { catchPanel?.close() }
    }

    func showSettings() {
        NSApp.activate()
        openSettings?()
    }

    #if DEBUG
    func showForDebugging(_ target: String) {
        switch target {
        case "settings": showSettings()
        case "catch":
            model.debugInjectCatch()
            showCatchPanel()
        default: showMain()
        }
    }
    #endif
}
