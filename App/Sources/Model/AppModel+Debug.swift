import Foundation
import DownhaulCore

#if DEBUG
extension AppModel {
    /// Puts a fake catch in the panel for UI checks: `-DownhaulShow catch`.
    func debugInjectCatch() {
        let incoming = IncomingDownload(url: "https://example.com/files/Example%20Archive.zip", filename: "Example Archive.zip", referrer: "https://example.com/")
        var pending = PendingCatch(incoming: incoming, media: false, name: "Example Archive.zip", folder: folder)
        pending.probe = ProbeResult(finalURL: URL(string: incoming.url)!, size: 734_003_200, acceptsRanges: true, validator: nil,
                                    suggestedName: "Example Archive.zip", contentType: "application/zip")
        appendPendingForDebugging(pending)
    }
}
#endif
