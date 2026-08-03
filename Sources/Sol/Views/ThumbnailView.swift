import SwiftUI
import AppKit

struct ThumbnailView: View {
    let game: Game
    let service: ThumbnailService
    let targetSize: CGSize?

    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("No Artwork", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .task(id: game.id) {
            await load()
        }
    }

    private func load() async {
        image = nil
        isLoading = true
        let pixelSize = targetPixelSize()
        let fetched = await service.fetchThumbnail(for: game, targetPixelSize: pixelSize)
        guard !Task.isCancelled else { return }
        image = fetched
        isLoading = false
    }

    private func targetPixelSize() -> Int? {
        guard let targetSize else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let maxDimension = max(targetSize.width, targetSize.height)
        return Int(maxDimension * scale)
    }
}
