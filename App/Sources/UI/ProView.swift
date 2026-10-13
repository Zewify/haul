import HaulCore
import SwiftUI

/// Haul Pro: what it unlocks, and the licence field (direct edition) or the purchase (store edition, wired at launch).
struct ProView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let license = model.license {
                    Label("Haul Pro is active", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    LabeledContent("Licensed to", value: license.licensee)
                    if license.id != "debug" { Button("Remove Licence") { model.removeLicense() } }
                } else {
                    Text("Haul Pro").font(.headline)
                    Text("Up to 32 connections per download and 8 downloads at a time" + (model.edition == .direct ? ", plus grabbing video and streams from pages." : "."))
                        .foregroundStyle(.secondary)
                }
            }
            if model.license == nil {
                switch model.edition {
                case .direct:
                    Section("Licence key") {
                        TextField("HAUL1-…", text: $key, axis: .vertical).lineLimit(3...6).font(.body.monospaced())
                        if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        HStack {
                            Spacer()
                            Button("Activate") { activate() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Buy a key at zewify.com/haul. The key is checked on this Mac; nothing is sent anywhere.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .store:
                    Section {
                        Text("Haul Pro will be a one-time purchase in this app. Purchasing is not wired up in this build.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func activate() {
        do {
            try model.setLicense(key)
            error = nil
            key = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
