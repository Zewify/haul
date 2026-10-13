import SwiftUI

/// Paste one link, or several on separate lines.
struct AddURLSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add downloads").font(.headline)
            Text("One link per line. Haul checks each link and names the file as the server does.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(adding ? "Adding…" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(adding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if text.isEmpty, let clip = NSPasteboard.general.string(forType: .string), let url = URL(string: clip.trimmingCharacters(in: .whitespacesAndNewlines)),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func add() {
        adding = true
        error = nil
        Task {
            do {
                try await model.addURLs(text)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
        }
    }
}
