import SwiftUI
import Foundation
import AppKit
import ImageIO
import os

private let widgetLogger = Logger(subsystem: "com.solemu.app.widgets", category: "WidgetData")

struct WidgetDataLoader {
    func loadSnapshot() -> SharedLauncherSnapshot? {
        let snapshot = SharedDataStore.shared.loadSnapshotSync()
        if snapshot == nil {
            widgetLogger.debug("No shared snapshot found.")
        }
        return snapshot
    }

    func image(for key: String) -> Image? {
        guard let data = SharedThumbnailStore.shared.imageData(for: key) else {
            widgetLogger.debug("No image data for key: \(key)")
            return nil
        }
        guard let image = decodeImage(from: data) else {
            widgetLogger.warning("Failed to decode image for key: \(key)")
            return nil
        }
        return Image(nsImage: image)
    }

    func recentGame(from snapshot: SharedLauncherSnapshot?) -> SharedGameRecord? {
        guard let snapshot else { return nil }
        if let lastId = snapshot.lastLaunchedId,
           let game = snapshot.games.first(where: { $0.id == lastId }) {
            return game
        }
        return snapshot.games
            .sorted { (lhs, rhs) in
                (lhs.lastPlayed ?? .distantPast) > (rhs.lastPlayed ?? .distantPast)
            }
            .first
    }

    func topPlayed(from snapshot: SharedLauncherSnapshot?, limit: Int) -> [SharedGameRecord] {
        guard let snapshot else { return [] }
        return snapshot.games.sorted { $0.hoursPlayed > $1.hoursPlayed }.prefix(limit).map { $0 }
    }

    private func decodeImage(from data: Data) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
