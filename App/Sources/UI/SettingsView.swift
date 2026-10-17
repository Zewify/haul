import DownhaulCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ConnectionSettings().tabItem { Label("Connections", systemImage: "network") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "globe") }
        }
        .frame(width: 520)
        .padding(.bottom, 8)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        Form {
            LabeledContent("Download folder") {
                HStack {
                    Text(Format.folder(model.folder.path(percentEncoded: false))).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { choose() }
                    if model.settings.downloadFolderPath != nil {
                        Button("Reset") { model.setFolder(AppModel.defaultFolder) }
                    }
                }
            }
            Toggle("Ask before starting a download from the browser", isOn: Binding(get: { model.settings.askBeforeStarting }, set: { model.setAskBeforeStarting($0) }))
            Toggle("Open Downhaul at login", isOn: Binding(get: { model.settings.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            Toggle("Check for updates once a day", isOn: Binding(get: { updates.isEnabled }, set: { updates.isEnabled = $0 }))
            Text("Downhaul keeps running in the menu bar when its window is closed, so the browser extension can always reach it.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url { model.setFolder(url) }
    }
}

struct ConnectionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(get: { model.settings.connections }, set: { model.setConnections($0) }), in: 1...Limits.maxConnections) {
                    LabeledContent("Connections per download", value: "\(model.settings.connections)")
                }
                Stepper(value: Binding(get: { model.settings.concurrent }, set: { model.setConcurrent($0) }), in: 1...Limits.maxConcurrent) {
                    LabeledContent("Downloads at a time", value: "\(model.settings.concurrent)")
                }
                Text("More connections help on fast servers; too many on a slow one only shares the same pipe thinner.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Speed") {
                Toggle("Limit download speed", isOn: Binding(get: { model.settings.limitSpeed }, set: { model.setLimitSpeed($0) }))
                LabeledContent("All downloads together") {
                    HStack(spacing: 6) {
                        TextField("Limit", value: Binding(get: { Double(model.settings.speedLimit) / 1_000_000 }, set: { model.setSpeedLimit(Int64(($0 * 1_000_000).rounded())) }),
                                  format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden().frame(width: 64).multilineTextAlignment(.trailing)
                        Text("MB/s").foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.settings.limitSpeed)
                Text("Keeps room for calls and streaming while Downhaul works. The menu bar menu turns it on and off.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Browser extension server") {
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText).labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                            .onSubmit { apply() }
                        Button("Apply") { apply() }.disabled(UInt16(portText) == nil || UInt16(portText) == model.settings.port)
                    }
                }
                if let error = model.serverError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else {
                    Label("Listening on 127.0.0.1:\(String(model.settings.port))", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                }
                Text("Change this only if another program already uses the port, and set the same port in the extension's options.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { portText = String(model.settings.port) }
    }

    private func apply() {
        if let port = UInt16(portText), port > 0 { model.setPort(port) }
    }
}

struct BrowserSettings: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Form {
            Section("Connected browsers") {
                if model.settings.pairedClients.isEmpty {
                    Text("No browser has connected yet. Install the extension, then press Connect in its popup and allow it here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.settings.pairedClients) { client in
                        LabeledContent(client.name, value: client.paired.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Forget All") { model.forgetPairedClients() }
                }
            }
            Section("Install the extension") {
                Group {
                    Text("Safari: the Downhaul extension comes with this app. Turn it on in Safari → Settings → Extensions.")
                    Text("Chrome, Edge, Brave, Arc, Vivaldi: open chrome://extensions, turn on Developer mode, click Load unpacked, press ⌘⇧G, paste this folder's path and choose it. After an update, press the reload arrow on Downhaul's card there.")
                    LabeledContent("Extension folder") {
                        HStack {
                            Text(Format.folder(Format.extensionFolder)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button(copied ? "Copied" : "Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Format.extensionFolder, forType: .string)
                                copied = true
                            }
                        }
                    }
                    Text("Then open the extension's popup and press Connect to Downhaul. Downloads the browser starts are handed to Downhaul; links to files are caught as you click them.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}
