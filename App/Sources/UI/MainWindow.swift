import HaulCore
import SwiftUI

/// The download list with its toolbar and filter.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowManager.self) private var windows
    @State private var filter: Filter = .all
    @State private var showingAdd = false
    @State private var selection: UUID?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", done = "Done", failed = "Failed"
        var id: String { rawValue }

        func matches(_ download: Download) -> Bool {
            switch self {
            case .all: true
            case .active: download.state.isActive || download.state == .paused
            case .done: download.state == .finished
            case .failed: if case .failed = download.state { true } else { download.state == .cancelled }
            }
        }
    }

    private var downloads: [Download] {
        model.engine.downloads.filter(filter.matches).reversed()
    }

    var body: some View {
        Group {
            if downloads.isEmpty {
                emptyState
            } else {
                List(downloads, selection: $selection) { download in
                    DownloadRow(download: download)
                        .listRowSeparator(.visible)
                        .contextMenu { RowActions(download: download) }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.engine.pauseAll() } label: { Label("Pause All", systemImage: "pause.fill") }
                    .help("Pause every download")
                    .disabled(!model.engine.downloads.contains { $0.state.isActive })
                Button { model.engine.resumeAll() } label: { Label("Resume All", systemImage: "play.fill") }
                    .help("Resume every paused download")
                    .disabled(!model.engine.downloads.contains { $0.state == .paused })
                Button { showingAdd = true } label: { Label("Add URL", systemImage: "plus") }
                    .help("Download a link")
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingAdd) { AddURLSheet().environment(model) }
        .safeAreaInset(edge: .bottom) { StatusBar() }
        .onDeleteCommand {
            // Only a download that is over; an active or paused one keeps its progress.
            if let selection { model.engine.removeIfDone(selection) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").font(.system(size: 44, weight: .thin)).foregroundStyle(.secondary)
            Text(filter == .all ? "No downloads yet" : "Nothing \(filter.rawValue.lowercased())").font(.title3)
            if filter == .all {
                Text("Add a link with ⌘N, or install the browser extension in Settings → Browser.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Combined speed and counts along the bottom.
struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        let active = engine.downloads.filter { $0.state.isActive }.count
        let combined = engine.combined
        HStack {
            Text(active == 0 ? "Idle" : "\(active) active")
            if combined.bytesPerSecond > 0 { Text("·").foregroundStyle(.tertiary); Text(Format.speed(combined.bytesPerSecond)) }
            Spacer()
            if !model.serverListening, let error = model.serverError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
            } else {
                Text(model.settings.pairedClients.isEmpty ? "No browser connected" : "Browser connected").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The per-download actions, shared by the row's buttons and its context menu.
struct RowActions: View {
    @Environment(AppModel.self) private var model
    let download: Download

    var body: some View {
        let engine = model.engine
        switch download.state {
        case .queued, .probing, .downloading:
            Button("Pause") { engine.pause(download.id) }
            Button("Cancel") { engine.cancel(download.id) }
        case .paused:
            Button("Resume") { engine.resume(download.id) }
            Button("Cancel") { engine.cancel(download.id) }
        case .failed, .cancelled:
            Button("Retry") { engine.retry(download.id) }
        case .finished:
            Button("Open") { if let path = download.finalPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
            Button("Show in Finder") { if let path = download.finalPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
        }
        Divider()
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(download.url.absoluteString, forType: .string)
        }
        Button("Remove from List") { engine.remove(download.id, deleteFile: false) }
        if download.state == .finished {
            Button("Remove and Delete File", role: .destructive) { engine.remove(download.id, deleteFile: true) }
        }
    }
}
