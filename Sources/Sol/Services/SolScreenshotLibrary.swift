import AppKit
import Foundation

struct SolScreenshot: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let title: String
    let capturedAt: Date
    let byteCount: Int64
}

@MainActor
final class SolScreenshotLibrary: ObservableObject {
    @Published private(set) var screenshots: [SolScreenshot] = []

    private var directoryURL: URL?
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func connect(to engineRootURL: URL?) {
        let next = engineRootURL?.appendingPathComponent("screenshots", isDirectory: true)
        guard next != directoryURL else { return }
        directoryURL = next
        reload()
    }

    func reload() {
        guard let directoryURL else {
            screenshots = []
            return
        }
        Task { [weak self, directoryURL] in
            let captures = await Task.detached(priority: .utility) {
                Self.loadScreenshots(from: directoryURL)
            }.value
            guard self?.directoryURL == directoryURL else { return }
            self?.screenshots = captures
        }
    }

    func registerScreenshot(at url: URL) {
        guard directoryURL?.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else {
            reload()
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let screenshot = SolScreenshot(
            id: url.standardizedFileURL.path,
            url: url,
            title: Self.title(from: url),
            capturedAt: values?.contentModificationDate ?? Date(),
            byteCount: Int64(values?.fileSize ?? 0)
        )
        screenshots.removeAll { $0.id == screenshot.id }
        screenshots.insert(screenshot, at: 0)
    }

    func reveal(_ screenshot: SolScreenshot) {
        NSWorkspace.shared.activateFileViewerSelecting([screenshot.url])
    }

    func open(_ screenshot: SolScreenshot) {
        NSWorkspace.shared.open(screenshot.url)
    }

    nonisolated private static func title(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let suffixPattern = #"_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$"#
        let cleaned = stem.replacingOccurrences(
            of: suffixPattern,
            with: "",
            options: .regularExpression
        )
        return cleaned.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated private static func loadScreenshots(from directoryURL: URL) -> [SolScreenshot] {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> SolScreenshot? in
            guard ["png", "jpg", "jpeg", "heic"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .contentModificationDateKey,
                      .fileSizeKey,
                  ]),
                  values.isRegularFile == true else { return nil }
            return SolScreenshot(
                id: url.standardizedFileURL.path,
                url: url,
                title: title(from: url),
                capturedAt: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }
}
