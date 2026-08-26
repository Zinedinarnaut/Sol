import AppKit
import SwiftUI

struct ProfileCapturesView: View {
    @ObservedObject var library: SolScreenshotLibrary
    @ObservedObject var cloudSync: SolCloudSyncService

    private let columns = [
        GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if library.screenshots.isEmpty {
                    ContentUnavailableView {
                        Label("No Screenshots Yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Press Shift-Command-S during a game. Captures will appear here and back up with your Sol profile.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(library.screenshots) { screenshot in
                            ScreenshotCard(
                                screenshot: screenshot,
                                onOpen: { library.open(screenshot) },
                                onReveal: { library.reveal(screenshot) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 34)
            .padding(.bottom, 46)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: library.reload)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Captures")
                    .font(.system(size: 34, weight: .semibold))

                Text("\(library.screenshots.count) saved \(library.screenshots.count == 1 ? "screenshot" : "screenshots")")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(cloudSync.state.title, systemImage: cloudSync.state.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                library.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ScreenshotCard: View {
    let screenshot: SolScreenshot
    let onOpen: () -> Void
    let onReveal: () -> Void

    private var image: NSImage? {
        NSImage(contentsOf: screenshot.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                ZStack {
                    Rectangle()
                        .fill(.quaternary)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 145)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipped()
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(screenshot.title)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(screenshot.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    ShareLink(item: screenshot.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Share Screenshot")

                    Button(action: onReveal) {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .font(.caption)
            }
            .padding(12)
        }
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(
                cornerRadius: SolGeometry.cardCornerRadius,
                style: .continuous
            )
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: SolGeometry.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: SolGeometry.cardCornerRadius,
                style: .continuous
            )
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .contextMenu {
            Button("Open", action: onOpen)
            ShareLink(item: screenshot.url) {
                Text("Share…")
            }
            Button("Show in Finder", action: onReveal)
        }
    }
}
