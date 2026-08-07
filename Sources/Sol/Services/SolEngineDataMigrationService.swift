import Foundation

struct SolEngineDataImportResult: Equatable, Sendable {
    let importedItemCount: Int
    let skippedItemCount: Int
}

actor SolEngineDataMigrationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importData(from sourceURL: URL, to destinationURL: URL) throws
        -> SolEngineDataImportResult {
        let source = sourceURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let destination = destinationURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let sourcePath = source.path
        let destinationPath = destination.path

        guard sourcePath != destinationPath,
              !sourcePath.hasPrefix(destinationPath + "/"),
              !destinationPath.hasPrefix(sourcePath + "/") else {
            throw ImportError.overlappingDirectories
        }

        let needsStop = source.startAccessingSecurityScopedResource()
        defer {
            if needsStop {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey])
        guard sourceValues.isDirectory == true else {
            throw ImportError.sourceIsNotDirectory
        }

        try fileManager.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let items = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var imported = 0
        var skipped = 0

        for sourceItem in items {
            let destinationItem = destination.appendingPathComponent(
                sourceItem.lastPathComponent,
                isDirectory: sourceItem.hasDirectoryPath
            )
            if fileManager.fileExists(atPath: destinationItem.path) {
                skipped += 1
                continue
            }

            do {
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
                imported += 1
            } catch {
                // copyItem can leave a partial directory. It is safe to remove
                // because this destination did not exist before this import.
                try? fileManager.removeItem(at: destinationItem)
                throw error
            }
        }

        return SolEngineDataImportResult(
            importedItemCount: imported,
            skippedItemCount: skipped
        )
    }

    private enum ImportError: LocalizedError {
        case overlappingDirectories
        case sourceIsNotDirectory

        var errorDescription: String? {
            switch self {
            case .overlappingDirectories:
                "Choose an existing engine-data folder outside Sol's data directory."
            case .sourceIsNotDirectory:
                "The selected engine-data location is not a folder."
            }
        }
    }
}
