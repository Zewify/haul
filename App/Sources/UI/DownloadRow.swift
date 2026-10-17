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
                // A finished download has nothing left to show as progress; its row says where the file is instead.
                // The clear stand-in keeps the row stretched to the list's width the way the bar did.
                if download.state != .finished {
                    SegmentMap(download: download)
                        .frame(height: 6)
                } else {
                    Color.clear.frame(height: 0)
                }
                HStack(spacing: 6) {
                    Text(detail).lineLimit(1)
                    Spacer()
                    if let note = download.mediaNote, download.state == .finished {
                        Label(note, systemImage: "speaker.slash").foregroundStyle(.orange)
                    } else if download.resumable == false, download.state.isRunning, download.kind == .file {
                        Text("Cannot resume").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .frame(maxWidth: .infinity)
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
            download.kind.isStream
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
             download.kind.isStream ? (download.mediaTrack == nil ? "stream" : "stream · \(download.mediaTrack == 0 ? "video" : "audio") track") : download.kind == .dash ? "part \(min((download.mediaDone ?? 0) + 1, 2)) of 2 · \(download.segments.filter { !$0.isComplete }.count) connections" : "\(download.segments.filter { !$0.isComplete }.count) connections"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .paused: "Paused" + (download.fraction.map { " · \(Format.percent($0))" } ?? "")
        case .finished:
            ["Done", download.finished.map { $0.formatted(date: .abbreviated, time: .shortened) }, folderDescription]
                .compactMap { $0 }.joined(separator: " · ")
        case .cancelled: "Cancelled"
        case .failed(let message): "Failed · \(message)"
        }
    }

    /// Where the finished file is: "~/Downloads".
    private var folderDescription: String? {
        download.finalPath.map { Format.folder(($0 as NSString).deletingLastPathComponent) }
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
                RowButton("folder", "Show in Finder") {
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
