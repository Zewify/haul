import HaulCore
import SwiftUI

/// The bar that shows every segment's filled part in place: the signature of a segmented downloader.
struct SegmentMap: View {
    let download: Download

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if download.state == .finished {
                    Capsule().fill(Color.accentColor.opacity(0.6))
                } else if download.kind == .hls, let fraction = download.fraction {
                    Capsule().fill(Color.accentColor).frame(width: max(0, width * fraction))
                } else if let size = download.size, size > 0 {
                    ForEach(Array(download.segments.enumerated()), id: \.offset) { _, segment in
                        let x = width * Double(segment.start) / Double(size)
                        let filled = width * Double(segment.written) / Double(size)
                        Rectangle()
                            .fill(download.state == .paused ? Color.secondary : Color.accentColor)
                            .frame(width: max(0, filled))
                            .offset(x: x)
                    }
                } else if download.state.isRunning {
                    Capsule().fill(Color.accentColor.opacity(0.4)).frame(width: width * 0.3)
                }
            }
            .clipShape(Capsule())
        }
    }
}
