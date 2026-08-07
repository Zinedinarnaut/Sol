import Foundation

struct SolEnginePaths {
    let executableURL: URL
    let dataDirectoryURL: URL?
}

final class SolEnginePathResolver {
    // Sol Engine consumes the compatible on-disk format inside a Sol-owned
    // location. Never probe another application's data directory on startup;
    // legacy data is copied only through the explicit native import flow.
    static let dataDirectoryName = "Sol"

    func resolveBundledNativeCore(in bundle: Bundle = .main) -> SolEnginePaths? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let executableURL = resourceURL
            .appendingPathComponent("SolEngine", isDirectory: true)
            .appendingPathComponent("Sol.Engine", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        guard SolEngineEmbeddedRuntime.bundledComponentIsAvailable(in: bundle) else {
            return nil
        }

        return SolEnginePaths(
            executableURL: executableURL,
            dataDirectoryURL: defaultNativeDataDirectory()
        )
    }

    private func defaultNativeDataDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Self.dataDirectoryName, isDirectory: true)
    }
}
