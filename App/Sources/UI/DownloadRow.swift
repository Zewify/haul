import HaulCore
import SwiftUI
import UniformTypeIdentifiers

/// One download: icon, name, the segment map, and what is happening to it.
struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let download: Download

    private var progress: DownloadProgress? { model.engine.progress(for: download.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(download.name.isEmpty ? download.url.lastPathComponent : download.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(trailing).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                SegmentMap(download: download)
                    .frame(height: 6)
                HStack(spacing: 6) {
                    Text(detail).lineLimit(1)
                    Spacer()
                    if download.resumable == false, download.state.isRunning, download.kind == .file {
                        Text("Cannot resume").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            actions
        }
        .padding(.vertical, 6)
    }

    private var icon: some View {
        let image: NSImage = {
            if let path = download.finalPath { return NSWorkspace.shared.icon(forFile: path) }
            let ext = (download.name as NSString).pathExtension
            if let type = UTType(filenameExtension: ext.isEmpty ? "bin" : ext) { return NSWorkspace.shared.icon(for: type) }
            return NSWorkspace.shared.icon(for: .data)
        }()
        return Image(nsImage: image).resizable().frame(width: 32, height: 32)
    }

    private var trailing: String {
        switch download.state {
        case .finished: Format.size(download.size)
        case .downloading, .probing:
            download.kind == .hls
                ? "\(download.mediaDone ?? 0) / \(download.mediaTotal ?? 0)"
                : "\(Format.size(download.bytesReceived)) / \(Format.size(download.size))"
        default: download.size.map { "\(Format.size(download.bytesReceived)) / \(Format.size($0))" } ?? Format.size(download.bytesReceived)
        }
    }

    private var detail: String {
        switch download.state {
        case .queued: "Queued"
        case .probing: "Connecting…"
        case .downloading:
            [Format.percent(download.fraction), Format.speed(progress?.bytesPerSecond ?? 0),
             (progress?.eta).map { "\(Format.eta($0)) left" } ?? "",
             download.kind == .file ? "\(download.segments.filter { !$0.isComplete }.count) connections" : "stream"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .paused: "Paused" + (download.fraction.map { " · \(Format.percent($0))" } ?? "")
        case .finished: download.finished.map { "Done · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Done"
        case .cancelled: "Cancelled"
        case .failed(let message): "Failed · \(message)"
        }
    }

    @ViewBuilder private var actions: some View {
        let engine = model.engine
        HStack(spacing: 4) {
            switch download.state {
            case .queued, .probing, .downloading:
                RowButton("pause.fill", "Pause") { engine.pause(download.id) }
                RowButton("xmark", "Cancel") { engine.cancel(download.id) }
            case .paused:
                RowButton("play.fill", "Resume") { engine.resume(download.id) }
                RowButton("xmark", "Cancel") { engine.cancel(download.id) }
            case .failed, .cancelled:
                RowButton("arrow.clockwise", "Retry") { engine.retry(download.id) }
                RowButton("trash", "Remove") { engine.remove(download.id, deleteFile: false) }
            case .finished:
                RowButton("magnifyingglass", "Show in Finder") {
                    if let path = download.finalPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                RowButton("trash", "Remove from list") { engine.remove(download.id, deleteFile: false) }
            }
        }
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
    }
}
