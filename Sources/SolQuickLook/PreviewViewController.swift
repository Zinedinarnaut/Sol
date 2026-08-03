import Cocoa
import Quartz
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hostingController: NSHostingController<PreviewView>?

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let preview = buildPreview(for: url)
        let hosting = NSHostingController(rootView: preview)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
        hostingController = hosting
        handler(nil)
    }

    private func buildPreview(for url: URL) -> PreviewView {
        var title = url.deletingPathExtension().lastPathComponent
        var image: NSImage?

        if let snapshot = SharedDataStore.shared.loadSnapshotSync(),
           let record = snapshot.games.first(where: { $0.filePath == url.path }) {
            title = record.title
            if let data = SharedThumbnailStore.shared.imageData(for: record.thumbnailKey) {
                image = NSImage(data: data)
            }
        }

        return PreviewView(title: title, image: image)
    }
}

struct PreviewView: View {
    let title: String
    let image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 16) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420, maxHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 320, height: 460)
                        .overlay(
                            Text("No Art")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.6))
                        )
                }

                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(20)
        }
    }
}
