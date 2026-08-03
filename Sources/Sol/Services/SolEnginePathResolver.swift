import Foundation

struct SolEnginePaths {
    let executableURL: URL
    let dataDirectoryURL: URL?
}

final class SolEnginePathResolver {
    // Sol Engine still consumes the upstream on-disk format. Keeping this
    // compatibility path avoids moving keys, firmware, saves, and DLC data.
    private static let upstreamDataDirectoryName = "Ryujinx"

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
            .appendingPathComponent(Self.upstreamDataDirectoryName, isDirectory: true)
    }
}
