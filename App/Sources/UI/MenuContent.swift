import KomizoCore
import SwiftUI

/// The menu bar item's menu: what is downloading, the combined speed, and the controls that matter from anywhere.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowManager.self) private var windows
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        let engine = model.engine
        if let version = updates.available {
            // Komizo is installed by its curl command, so updating is running it again.
            Text("Komizo \(version.description) is available")
            Button("Copy Install Command") { updates.copyInstallCommand() }
            Text("Then paste it into Terminal")
            Divider()
        }
        let active = engine.downloads.filter { $0.state.isActive }
        let combined = engine.combined
        if active.isEmpty {
            Text("Nothing downloading")
        } else {
            Text("\(active.count) downloading" + (combined.bytesPerSecond > 0 ? " · \(Format.speed(combined.bytesPerSecond))" : ""))
            ForEach(active.suffix(5)) { download in
                Button {
                    windows.showMain()
                } label: {
                    Text("\(Format.percent(download.fraction))  \(download.name.isEmpty ? download.url.lastPathComponent : download.name)")
                }
            }
        }
        Divider()
        Button("Pause All") { engine.pauseAll() }.disabled(active.isEmpty)
        Button("Resume All") { engine.resumeAll() }.disabled(!engine.downloads.contains { $0.state == .paused })
        Toggle("Limit Speed to \(Format.speed(Double(model.settings.speedLimit)))", isOn: Binding(get: { model.settings.limitSpeed }, set: { model.setLimitSpeed($0) }))
        Divider()
        Button("Open Komizo") { windows.showMain() }.keyboardShortcut("o")
        Button("Settings…") { windows.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Komizo") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
