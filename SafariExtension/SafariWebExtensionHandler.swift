import SafariServices
import os

/// The native side of the Safari Web Extension. The extension talks to the app over its local server, so this
/// handler has nothing to do but exist; Safari requires one.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response])
    }
}
