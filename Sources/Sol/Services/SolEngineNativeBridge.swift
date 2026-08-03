import Darwin
import Foundation

struct SolEngineNativeStatus: Equatable {
    let protocolVersion: Int
    let supportsConfiguration: Bool
    let supportsHeadlessLaunch: Bool
    let supportsEmbeddedSurface: Bool
    let supportsSessionControl: Bool
    let supportsBackendManagement: Bool
    let supportsNativeCocoaWindow: Bool
    let supportsNativeDialogs: Bool
    let supportsNativeInputRouting: Bool
}

final class SolEngineNativeBridge {
    private typealias IntFunction = @convention(c) () -> Int32

    static let detectedStatus: SolEngineNativeStatus? = SolEngineNativeBridge()?.status()

    private let handle: UnsafeMutableRawPointer

    init?(bundle: Bundle = .main) {
        let candidates = [
            bundle.privateFrameworksURL?.appendingPathComponent("Sol.Engine.NativeHost.dylib"),
            bundle.privateFrameworksURL?.appendingPathComponent("libSol.Engine.NativeHost.dylib"),
        ].compactMap { $0 }

        guard let libraryURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        self.handle = handle
    }

    deinit {
        // Native AOT shared libraries are process-lifetime components and must
        // not be unloaded with dlclose.
    }

    func status() -> SolEngineNativeStatus? {
        guard let version = call("sol_engine_protocol_version"),
              let capabilities = call("sol_engine_capabilities") else {
            return nil
        }

        return SolEngineNativeStatus(
            protocolVersion: Int(version),
            supportsConfiguration: capabilities & (1 << 0) != 0,
            supportsHeadlessLaunch: capabilities & (1 << 1) != 0,
            supportsEmbeddedSurface: capabilities & (1 << 2) != 0,
            supportsSessionControl: capabilities & (1 << 3) != 0,
            supportsBackendManagement: capabilities & (1 << 4) != 0,
            supportsNativeCocoaWindow: capabilities & (1 << 5) != 0,
            supportsNativeDialogs: capabilities & (1 << 6) != 0,
            supportsNativeInputRouting: capabilities & (1 << 7) != 0
        )
    }

    private func call(_ symbol: String) -> Int32? {
        guard let rawFunction = dlsym(handle, symbol) else { return nil }
        let function = unsafeBitCast(rawFunction, to: IntFunction.self)
        return function()
    }
}
