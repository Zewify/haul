import SwiftUI

/// Which sites Downhaul's grabber has been checked on, opened from the main window's toolbar.
struct TestedSitesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Video from websites").font(.headline)
                Text("Play the video, then click the Downhaul icon in your browser. The one you are watching is listed first, as Playing now.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("Tested", systemImage: "checkmark.circle.fill", tint: .green, sites: TestedSites.works)
            Text("Most other sites work too, when they play an ordinary video file or an HLS or DASH stream.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            group("Cannot be saved", systemImage: "xmark.circle.fill", tint: .secondary, sites: TestedSites.doesNotWork)
            Text("Tested on \(TestedSites.testedOn), with public videos, signed out. Sites change their players, so one may stop working before Downhaul catches up.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
    }

    private func group(_ title: String, systemImage: String, tint: Color, sites: [TestedSites.Site]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(sites) { site in
                    GridRow {
                        Text(site.name).font(.callout.weight(.medium))
                        Text(site.what).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
