import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        handleShare()
    }

    private func handleShare() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        let providers = items.compactMap { $0.attachments }.flatMap { $0 }
        guard let provider = providers.first else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        let typeIdentifier = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    SharedDataStore.shared.setPendingLaunch(path: url.path)
                    DispatchQueue.main.async {
                        if let deepLink = URL(string: "sol://launch?path=\(url.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                            NSWorkspace.shared.open(deepLink)
                        }
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                }
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
