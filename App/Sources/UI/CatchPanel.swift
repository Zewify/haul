import HaulCore
import SwiftUI

/// A download the browser handed over, waiting for the user: name, folder, Start.
struct CatchPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowManager.self) private var windows
    @State private var name = ""
    @State private var folder: URL?
    @State private var editingID: UUID?

    private var pending: PendingCatch? { model.pending.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pending {
                HStack(spacing: 10) {
                    Image(systemName: pending.kind == .hls ? "play.rectangle" : "arrow.down.doc")
                        .font(.title).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.incoming.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 6) {
                            if let probe = pending.probe {
                                Text(Format.size(probe.size))
                                if let type = probe.contentType { Text("·").foregroundStyle(.tertiary); Text(type) }
                                if !probe.acceptsRanges, probe.size != nil { Text("·").foregroundStyle(.tertiary); Text("cannot resume") }
                            } else if pending.kind == .hls {
                                Text("HLS stream")
                            } else if let error = pending.error {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        .font(.caption)
                    }
                }
                Form {
                    TextField("Save as", text: $name)
                    LabeledContent("Folder") {
                        HStack {
                            Text((folder ?? pending.folder).lastPathComponent).lineLimit(1)
                            Spacer()
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                .formStyle(.columns)
                HStack {
                    if model.pending.count > 1 { Text("\(model.pending.count - 1) more waiting").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { finish(start: false) }.keyboardShortcut(.cancelAction)
                    Button("Start") { finish(start: true) }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Text("Nothing waiting").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: pending?.id, initial: true) { _, _ in load() }
    }

    private func load() {
        guard let pending, pending.id != editingID else { return }
        editingID = pending.id
        name = pending.name
        folder = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder ?? pending?.folder
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func finish(start: Bool) {
        guard var pending else { return }
        if start {
            pending.name = Filename.sanitised(name)
            if let folder { pending.folder = folder }
            model.startCatch(pending)
        } else {
            model.dismissCatch(pending)
        }
        windows.closeCatchPanelIfIdle()
    }
}
