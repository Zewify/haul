// Presses Start in Downhaul's catch panel through the accessibility API, the way VoiceOver would.
// System Events cannot read SwiftUI's button labels (they live in AXDescription), so this talks to AX directly.
// Exits 0 once pressed, 2 if Start is disabled, 1 if there is no panel.
import AppKit
import ApplicationServices

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func findStart(in element: AXUIElement) -> AXUIElement? {
    if value(element, kAXRoleAttribute) as? String == kAXButtonRole, value(element, kAXDescriptionAttribute) as? String == "Start" { return element }
    for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        if let found = findStart(in: child) { return found }
    }
    return nil
}

guard let downhaul = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zewify.downhaul").first else { exit(1) }
let app = AXUIElementCreateApplication(downhaul.processIdentifier)
let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let panel = windows.first(where: { value($0, kAXTitleAttribute) as? String == "Download" }), let start = findStart(in: panel) else { exit(1) }
guard value(start, kAXEnabledAttribute) as? Bool != false else { exit(2) }
exit(AXUIElementPerformAction(start, kAXPressAction as CFString) == .success ? 0 : 1)
