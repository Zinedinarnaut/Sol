import AppKit
import Darwin
import Foundation
import Metal
import QuartzCore

private let schemaVersion = 1
private let sourceName = "solmetal-embedded-host"
private let defaultAppPath = "/tmp/sol-derived-data/Build/Products/Debug/Sol.app"
private let maximumEventBytes = 4 * 1024 * 1024

nonisolated(unsafe) private var pendingSignal: sig_atomic_t = 0

private func compatibilitySignalHandler(_ signalNumber: Int32) {
    pendingSignal = signalNumber
}

private struct HostFailure: Error {
    let code: String
}

private final class JSONLineEmitter: @unchecked Sendable {
    private let output: FileHandle
    private let lock = NSLock()
    private var sequence = 0

    init() throws {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else {
            throw HostFailure(code: "public_output_unavailable")
        }
        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }

        sequence += 1
        var payload = fields
        payload["schemaVersion"] = schemaVersion
        payload["source"] = sourceName
        payload["event"] = event
        payload["sequence"] = sequence

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                  withJSONObject: payload,
                  options: [.sortedKeys]
              ) else {
            return
        }

        var line = data
        line.append(0x0a)
        do {
            try output.write(contentsOf: line)
        } catch {
            // A closed consumer is not a reason to leak diagnostics through
            // the process' redirected stdout or stderr.
        }
    }
}

private struct Options {
    enum Mode {
        case run
        case runtimeSmoke
        case help
    }

    var mode: Mode = .run
    var appURL = URL(fileURLWithPath: defaultAppPath, isDirectory: true)
    var gameURL: URL?
    var dataDirectoryURL: URL?
    var width = 1280
    var height = 720
    var warmupSeconds = 15.0
    var durationSeconds = 30.0
    var firstFrameTimeoutSeconds = 180.0
    var stopTimeoutSeconds = 20.0
    var hidden = false
    var testRuntimeURL: URL?

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var options = Options()
        if let configuredApp = environment["SOL_COMPATIBILITY_APP"], !configuredApp.isEmpty {
            options.appURL = URL(fileURLWithPath: configuredApp, isDirectory: true)
        }
        if let game = environment["SOL_PRIVATE_GAME_PATH"], !game.isEmpty {
            options.gameURL = URL(fileURLWithPath: game)
        }
        if let data = environment["SOL_PRIVATE_DATA_PATH"], !data.isEmpty {
            options.dataDirectoryURL = URL(fileURLWithPath: data, isDirectory: true)
        }

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--runtime-smoke":
                options.mode = .runtimeSmoke
            case "--help", "-h":
                options.mode = .help
            case "--hidden":
                options.hidden = true
            case "--app":
                options.appURL = URL(
                    fileURLWithPath: try value(after: &index, in: arguments),
                    isDirectory: true
                )
            case "--game":
                options.gameURL = URL(
                    fileURLWithPath: try value(after: &index, in: arguments)
                )
            case "--data":
                options.dataDirectoryURL = URL(
                    fileURLWithPath: try value(after: &index, in: arguments),
                    isDirectory: true
                )
            case "--width":
                options.width = try integer(after: &index, in: arguments)
            case "--height":
                options.height = try integer(after: &index, in: arguments)
            case "--warmup":
                options.warmupSeconds = try number(after: &index, in: arguments)
            case "--duration":
                options.durationSeconds = try number(after: &index, in: arguments)
            case "--first-frame-timeout":
                options.firstFrameTimeoutSeconds = try number(after: &index, in: arguments)
            case "--stop-timeout":
                options.stopTimeoutSeconds = try number(after: &index, in: arguments)
            case "--test-runtime":
#if SOL_COMPATIBILITY_HOST_TESTING
                options.testRuntimeURL = URL(
                    fileURLWithPath: try value(after: &index, in: arguments)
                )
#else
                throw HostFailure(code: "test_runtime_disabled")
#endif
            default:
                throw HostFailure(code: "unknown_argument")
            }
            index += 1
        }

        guard (64...8192).contains(options.width),
              (64...8192).contains(options.height),
              options.width * options.height <= 33_554_432 else {
            throw HostFailure(code: "invalid_surface_size")
        }
        guard options.warmupSeconds.isFinite,
              (0...600).contains(options.warmupSeconds) else {
            throw HostFailure(code: "invalid_warmup")
        }
        guard options.durationSeconds.isFinite,
              (5...600).contains(options.durationSeconds) else {
            throw HostFailure(code: "invalid_duration")
        }
        guard options.firstFrameTimeoutSeconds.isFinite,
              (1...600).contains(options.firstFrameTimeoutSeconds) else {
            throw HostFailure(code: "invalid_first_frame_timeout")
        }
        guard options.stopTimeoutSeconds.isFinite,
              (1...120).contains(options.stopTimeoutSeconds) else {
            throw HostFailure(code: "invalid_stop_timeout")
        }
        return options
    }

    private static func value(after index: inout Int, in arguments: [String]) throws -> String {
        index += 1
        guard index < arguments.count, !arguments[index].isEmpty else {
            throw HostFailure(code: "missing_argument_value")
        }
        return arguments[index]
    }

    private static func integer(after index: inout Int, in arguments: [String]) throws -> Int {
        guard let parsed = Int(try value(after: &index, in: arguments)) else {
            throw HostFailure(code: "invalid_integer")
        }
        return parsed
    }

    private static func number(after index: inout Int, in arguments: [String]) throws -> Double {
        guard let parsed = Double(try value(after: &index, in: arguments)) else {
            throw HostFailure(code: "invalid_number")
        }
        return parsed
    }
}

private struct PrivateRunFiles {
    let directoryURL: URL
    let rawLogURL: URL
    let benchmarkURL: URL

    static func create(in dataDirectory: URL, runID: String) throws -> PrivateRunFiles {
        let base = dataDirectory
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("SolMetalCompatibility", isDirectory: true)
        let directory = base.appendingPathComponent("Run-\(runID)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            throw HostFailure(code: "private_run_directory_unavailable")
        }

        return PrivateRunFiles(
            directoryURL: directory,
            rawLogURL: directory.appendingPathComponent("engine.raw.log"),
            benchmarkURL: directory.appendingPathComponent("benchmark.raw.json")
        )
    }

    func redirectProcessDiagnostics() throws {
        let descriptor = open(rawLogURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw HostFailure(code: "private_log_unavailable")
        }
        defer { close(descriptor) }

        guard dup2(descriptor, STDOUT_FILENO) >= 0,
              dup2(descriptor, STDERR_FILENO) >= 0 else {
            throw HostFailure(code: "diagnostic_redirection_failed")
        }
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
    }
}

private func redirectProcessDiagnosticsToNull() throws {
    let descriptor = open("/dev/null", O_WRONLY)
    guard descriptor >= 0 else {
        throw HostFailure(code: "diagnostic_redirection_failed")
    }
    defer { close(descriptor) }
    guard dup2(descriptor, STDOUT_FILENO) >= 0,
          dup2(descriptor, STDERR_FILENO) >= 0 else {
        throw HostFailure(code: "diagnostic_redirection_failed")
    }
}

private struct RuntimeLayout {
    let resourcesURL: URL
    let managedDirectoryURL: URL
    let dotnetRootURL: URL
    let runtimeConfigURL: URL
    let assemblyURL: URL
    let hostfxrURL: URL
    let solMetalURL: URL

    init(appURL: URL) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let managed = resources.appendingPathComponent("SolEngineManaged", isDirectory: true)
        let dotnet = resources.appendingPathComponent("Dotnet", isDirectory: true)
        let runtimeConfig = managed.appendingPathComponent("Sol.Engine.runtimeconfig.json")
        let assembly = managed.appendingPathComponent("Sol.Engine.dll")
        let solMetal = contents
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("SolMetal.dylib")

        guard appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: contents.path),
              FileManager.default.fileExists(atPath: runtimeConfig.path),
              FileManager.default.fileExists(atPath: assembly.path),
              FileManager.default.fileExists(atPath: solMetal.path) else {
            throw HostFailure(code: "runtime_resources_unavailable")
        }

        let fxrRoot = dotnet
            .appendingPathComponent("host", isDirectory: true)
            .appendingPathComponent("fxr", isDirectory: true)
        let versions: [URL]
        do {
            versions = try FileManager.default.contentsOfDirectory(
                at: fxrRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedAscending
            }
        } catch {
            throw HostFailure(code: "dotnet_host_unavailable")
        }
        guard let hostfxr = versions
            .map({ $0.appendingPathComponent("libhostfxr.dylib") })
            .last(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw HostFailure(code: "dotnet_host_unavailable")
        }

        let sharedRoot = dotnet
            .appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent("Microsoft.NETCore.App", isDirectory: true)
        let coreRuntimeAvailable = ((try? FileManager.default.contentsOfDirectory(
            at: sharedRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).contains {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("libcoreclr.dylib").path
            )
        }
        guard coreRuntimeAvailable else {
            throw HostFailure(code: "dotnet_runtime_unavailable")
        }

        resourcesURL = resources
        managedDirectoryURL = managed
        dotnetRootURL = dotnet
        runtimeConfigURL = runtimeConfig
        assemblyURL = assembly
        hostfxrURL = hostfxr
        solMetalURL = solMetal
    }
}

private protocol EmbeddedRuntime: AnyObject {
    func start(
        cocoaView: UnsafeMutableRawPointer,
        metalLayer: UnsafeMutableRawPointer,
        gamePath: String,
        dataDirectory: String,
        width: Int32,
        height: Int32
    ) -> Int32
    func pump() -> Int32
    func readEvent() -> Data?
    func sendCommand(_ json: String) -> Int32
    func shutdown() -> Int32
}

private final class ManagedEmbeddedRuntime: EmbeddedRuntime {
    private typealias HostfxrInitialize = @convention(c) (
        UnsafePointer<CChar>,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    private typealias HostfxrGetRuntimeDelegate = @convention(c) (
        UnsafeMutableRawPointer?,
        Int32,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    private typealias HostfxrClose = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias LoadAssemblyAndGetFunctionPointer = @convention(c) (
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>
    ) -> Int32
    private typealias StartFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>?,
        UnsafePointer<UInt8>?,
        Int32,
        Int32
    ) -> Int32
    private typealias NoArgumentFunction = @convention(c) () -> Int32
    private typealias ReadEventFunction = @convention(c) (
        UnsafeMutablePointer<UInt8>?,
        Int32
    ) -> Int32
    private typealias SendCommandFunction = @convention(c) (UnsafePointer<UInt8>?) -> Int32

    private struct HostfxrInitializeParameters {
        var size: Int
        var hostPath: UnsafePointer<CChar>?
        var dotnetRoot: UnsafePointer<CChar>?
    }

    private let libraryHandle: UnsafeMutableRawPointer
    private let startFunction: StartFunction
    private let pumpFunction: NoArgumentFunction
    private let readEventFunction: ReadEventFunction
    private let sendCommandFunction: SendCommandFunction
    private let shutdownFunction: NoArgumentFunction

    init(layout: RuntimeLayout) throws {
        setenv("DOTNET_ROOT", layout.dotnetRootURL.path, 1)

        guard let libraryHandle = dlopen(layout.hostfxrURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw HostFailure(code: "dotnet_host_load_failed")
        }
        self.libraryHandle = libraryHandle

        let initialize: HostfxrInitialize = try Self.loadSymbol(
            "hostfxr_initialize_for_runtime_config",
            from: libraryHandle
        )
        let getRuntimeDelegate: HostfxrGetRuntimeDelegate = try Self.loadSymbol(
            "hostfxr_get_runtime_delegate",
            from: libraryHandle
        )
        let close: HostfxrClose = try Self.loadSymbol("hostfxr_close", from: libraryHandle)

        var context: UnsafeMutableRawPointer?
        let initializeResult = layout.runtimeConfigURL.path.withCString { runtimeConfigPath in
            layout.dotnetRootURL.path.withCString { dotnetRootPath in
                (CommandLine.arguments.first ?? "SolMetalCompatibilityHost").withCString { hostPath in
                    var parameters = HostfxrInitializeParameters(
                        size: MemoryLayout<HostfxrInitializeParameters>.size,
                        hostPath: hostPath,
                        dotnetRoot: dotnetRootPath
                    )
                    return withUnsafePointer(to: &parameters) {
                        initialize(runtimeConfigPath, UnsafeRawPointer($0), &context)
                    }
                }
            }
        }
        guard initializeResult >= 0, let context else {
            throw HostFailure(code: "dotnet_runtime_initialize_failed")
        }
        defer { _ = close(context) }

        var loaderPointer: UnsafeMutableRawPointer?
        let getDelegateResult = getRuntimeDelegate(context, 5, &loaderPointer)
        guard getDelegateResult >= 0, let loaderPointer else {
            throw HostFailure(code: "dotnet_component_loader_unavailable")
        }
        let loadAssembly = unsafeBitCast(
            loaderPointer,
            to: LoadAssemblyAndGetFunctionPointer.self
        )

        startFunction = try Self.loadManagedMethod(
            "Start",
            assembly: layout.assemblyURL.path,
            using: loadAssembly,
            as: StartFunction.self
        )
        pumpFunction = try Self.loadManagedMethod(
            "Pump",
            assembly: layout.assemblyURL.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
        readEventFunction = try Self.loadManagedMethod(
            "ReadEvent",
            assembly: layout.assemblyURL.path,
            using: loadAssembly,
            as: ReadEventFunction.self
        )
        sendCommandFunction = try Self.loadManagedMethod(
            "SendCommand",
            assembly: layout.assemblyURL.path,
            using: loadAssembly,
            as: SendCommandFunction.self
        )
        shutdownFunction = try Self.loadManagedMethod(
            "Shutdown",
            assembly: layout.assemblyURL.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
    }

    func start(
        cocoaView: UnsafeMutableRawPointer,
        metalLayer: UnsafeMutableRawPointer,
        gamePath: String,
        dataDirectory: String,
        width: Int32,
        height: Int32
    ) -> Int32 {
        gamePath.withCString { gamePointer in
            dataDirectory.withCString { dataPointer in
                startFunction(
                    cocoaView,
                    metalLayer,
                    nil,
                    nil,
                    UnsafeRawPointer(gamePointer).assumingMemoryBound(to: UInt8.self),
                    UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self),
                    width,
                    height
                )
            }
        }
    }

    func pump() -> Int32 {
        pumpFunction()
    }

    func readEvent() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let result = buffer.withUnsafeMutableBufferPointer {
                readEventFunction($0.baseAddress, Int32($0.count))
            }
            if result == 0 {
                return nil
            }
            if result < 0 {
                let required = Int(-result)
                guard required > 0, required <= maximumEventBytes else {
                    return nil
                }
                buffer = [UInt8](repeating: 0, count: required)
                continue
            }
            guard result <= buffer.count else {
                return nil
            }
            return Data(buffer.prefix(Int(result)))
        }
    }

    func sendCommand(_ json: String) -> Int32 {
        json.withCString {
            sendCommandFunction(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self))
        }
    }

    func shutdown() -> Int32 {
        shutdownFunction()
    }

    private static func loadManagedMethod<T>(
        _ method: String,
        assembly: String,
        using loader: LoadAssemblyAndGetFunctionPointer,
        as type: T.Type
    ) throws -> T {
        var functionPointer: UnsafeMutableRawPointer?
        let unmanagedCallersOnly = UnsafePointer<CChar>(bitPattern: UInt.max)
        let result = assembly.withCString { assemblyPath in
            "Ryujinx.Headless.NativeEmbeddedEntrypoint, Sol.Engine".withCString { typeName in
                method.withCString { methodName in
                    loader(
                        assemblyPath,
                        typeName,
                        methodName,
                        unmanagedCallersOnly,
                        nil,
                        &functionPointer
                    )
                }
            }
        }
        guard result >= 0, let functionPointer else {
            throw HostFailure(code: "managed_abi_unavailable")
        }
        return unsafeBitCast(functionPointer, to: type)
    }

    private static func loadSymbol<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer
    ) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw HostFailure(code: "dotnet_host_symbol_unavailable")
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

#if SOL_COMPATIBILITY_HOST_TESTING
private final class DirectTestRuntime: EmbeddedRuntime {
    private typealias StartFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafePointer<UInt8>?,
        UnsafePointer<UInt8>?,
        Int32,
        Int32
    ) -> Int32
    private typealias NoArgumentFunction = @convention(c) () -> Int32
    private typealias ReadEventFunction = @convention(c) (
        UnsafeMutablePointer<UInt8>?,
        Int32
    ) -> Int32
    private typealias SendCommandFunction = @convention(c) (UnsafePointer<UInt8>?) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let startFunction: StartFunction
    private let pumpFunction: NoArgumentFunction
    private let readEventFunction: ReadEventFunction
    private let sendCommandFunction: SendCommandFunction
    private let shutdownFunction: NoArgumentFunction

    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw HostFailure(code: "test_runtime_load_failed")
        }
        self.handle = handle
        startFunction = try Self.symbol("Start", handle: handle)
        pumpFunction = try Self.symbol("Pump", handle: handle)
        readEventFunction = try Self.symbol("ReadEvent", handle: handle)
        sendCommandFunction = try Self.symbol("SendCommand", handle: handle)
        shutdownFunction = try Self.symbol("Shutdown", handle: handle)
    }

    func start(
        cocoaView: UnsafeMutableRawPointer,
        metalLayer: UnsafeMutableRawPointer,
        gamePath: String,
        dataDirectory: String,
        width: Int32,
        height: Int32
    ) -> Int32 {
        gamePath.withCString { gamePointer in
            dataDirectory.withCString { dataPointer in
                startFunction(
                    cocoaView,
                    metalLayer,
                    nil,
                    nil,
                    UnsafeRawPointer(gamePointer).assumingMemoryBound(to: UInt8.self),
                    UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self),
                    width,
                    height
                )
            }
        }
    }

    func pump() -> Int32 { pumpFunction() }

    func readEvent() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let result = buffer.withUnsafeMutableBufferPointer {
                readEventFunction($0.baseAddress, Int32($0.count))
            }
            if result == 0 { return nil }
            if result < 0 {
                let required = Int(-result)
                guard required > 0, required <= maximumEventBytes else { return nil }
                buffer = [UInt8](repeating: 0, count: required)
                continue
            }
            guard result <= buffer.count else { return nil }
            return Data(buffer.prefix(Int(result)))
        }
    }

    func sendCommand(_ json: String) -> Int32 {
        json.withCString {
            sendCommandFunction(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self))
        }
    }

    func shutdown() -> Int32 { shutdownFunction() }

    private static func symbol<T>(_ name: String, handle: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw HostFailure(code: "test_runtime_symbol_unavailable")
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}
#endif

@MainActor
private final class MetalSurfaceView: NSView {
    private let requestedPixelSize: CGSize

    init(pixelWidth: Int, pixelHeight: Int, logicalSize: CGSize) {
        requestedPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        super.init(frame: NSRect(origin: .zero, size: logicalSize))
        wantsLayer = true
        updateMetalLayer()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        return layer
    }

    override func layout() {
        super.layout()
        updateMetalLayer()
    }

    var metalLayer: CAMetalLayer? {
        layer as? CAMetalLayer
    }

    private func updateMetalLayer() {
        guard let metalLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        metalLayer.drawableSize = requestedPixelSize
        CATransaction.commit()
    }
}

@MainActor
private final class CompatibilityWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private let safeManagedScalarKeys: Set<String> = [
    "protocol", "event", "phase", "paused", "fullscreen", "volume",
    "vsyncMode", "command", "operation", "firmwareVersion", "hasProdKeys",
    "success", "exitCode", "requestId", "dialogKind", "inputMode",
    "minimumLength", "maximumLength", "cursorBegin", "cursorEnd",
    "overwriteMode", "inputKind", "playerIndex", "usesEastConfirmButton",
    "isConnected", "bindingValue", "deadzoneLeft", "deadzoneRight",
    "rangeLeft", "rangeRight", "triggerThreshold", "motionEnabled",
    "motionSensitivity", "gyroDeadzone", "rumbleEnabled", "strongRumble",
    "weakRumble", "hdRumble", "ledEnabled", "ledOff", "ledRainbow",
    "ledColor", "isDefault", "playable", "abiVersion", "deviceName",
    "appleGpuFamily", "argumentBufferTier", "unifiedMemory",
    "supportsBcTextureCompression", "supportsRayTracing",
    "supportsBinaryArchives", "spirvTranslationReady", "bufferResourcesReady",
    "textureResourcesReady", "samplerResourcesReady", "computePipelinesReady",
    "renderPipelinesReady", "renderBindingsReady", "indexedDrawingReady",
    "depthStencilReady", "blendingReady", "rasterizerStateReady",
    "timelineSynchronizationReady", "recommendedWorkingSetBytes", "testsRun",
    "testsPassed", "bytesVerified", "shaderCacheHits", "shaderCacheMisses",
    "binaryArchivesCreated", "gpuMilliseconds", "outputSignature",
    "managedLiveBytes", "managedHeapBytes", "managedCommittedBytes",
    "managedFragmentedBytes", "processWorkingSetBytes", "hvAddressSpaces",
    "hvVcpus", "count", "dlcCount", "updateCount", "directoryCount",
    "addedCount", "removedCount", "providerStage", "providerGeneration",
    "sceneReady", "depthReady", "motionReady", "rawExportReady",
    "exportReady", "sceneCut", "depthFormat", "motionFormat", "width",
    "height", "loadStage", "progressCurrent", "progressTotal",
    "playtimeSeconds", "lastPlayedUtc", "activityTimestamp", "activityKind",
    "activityVersion"
]

private func safeManagedEvent(_ raw: [String: Any]) -> [String: Any] {
    var safe: [String: Any] = [:]
    for (key, value) in raw where safeManagedScalarKeys.contains(key) {
        switch value {
        case is NSNull, is Bool, is NSNumber:
            safe[key] = value
        case let string as String:
            if string.count <= 256,
               !string.contains("/"),
               !string.contains("\\"),
               !string.contains("://") {
                safe[key] = string
            }
        default:
            break
        }
    }
    if let capabilities = raw["capabilities"] as? [String] {
        safe["capabilities"] = capabilities.filter {
            $0.range(of: "^[A-Za-z0-9._-]{1,80}$", options: .regularExpression) != nil
        }
    }
    return safe
}

private struct BenchmarkSummary {
    let publicFields: [String: Any]
    let completed: Bool
    let canonicalBackend: String?

    static func read(from url: URL) -> BenchmarkSummary? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var safe: [String: Any] = [:]
        let scalarKeys = [
            "schemaVersion", "completed", "configuredWarmupSeconds",
            "configuredDurationSeconds", "measuredSeconds", "presentedFrames",
            "presentedFramesPerSecond"
        ]
        for key in scalarKeys {
            if let value = root[key], value is NSNumber || value is Bool {
                safe[key] = value
            }
        }
        let distributionKeys = [
            "sourceFramesPerSecond", "presentFrameTimeMilliseconds", "fifoPercent",
            "processCpuPercent", "workingSetBytes"
        ]
        let statisticKeys = ["samples", "mean", "median", "p95", "p99", "minimum", "maximum"]
        for key in distributionKeys {
            guard let distribution = root[key] as? [String: Any] else { continue }
            var safeDistribution: [String: Any] = [:]
            for statistic in statisticKeys {
                if let value = distribution[statistic] as? NSNumber {
                    safeDistribution[statistic] = value
                }
            }
            safe[key] = safeDistribution
        }

        let canonicalBackend: String?
        switch (root["backend"] as? String)?.lowercased() {
        case "solmetal":
            canonicalBackend = "solmetal"
        case "moltenvk", "vulkan":
            canonicalBackend = "moltenvk"
        default:
            canonicalBackend = nil
        }
        safe["backend"] = canonicalBackend ?? "unattested"
        return BenchmarkSummary(
            publicFields: safe,
            completed: (root["completed"] as? Bool) == true,
            canonicalBackend: canonicalBackend
        )
    }
}

@MainActor
private final class CompatibilityRun {
    private let options: Options
    private let emitter: JSONLineEmitter
    private let runtime: EmbeddedRuntime
    private let privateFiles: PrivateRunFiles
    private let runID: String
    private let surface: MetalSurfaceView
    private let window: NSWindow
    private let windowDelegate = CompatibilityWindowDelegate()

    private var closeRequested = false
    private var firstFrameAt: Date?
    private var sawSolMetalLaunchStage = false
    private var terminationExitCode: Int?
    private var stopRequestedAt: Date?
    private var stopCommandAccepted = false
    private var shutdownAccepted = false
    private var benchmark: BenchmarkSummary?

    init(
        options: Options,
        emitter: JSONLineEmitter,
        runtime: EmbeddedRuntime,
        privateFiles: PrivateRunFiles,
        runID: String
    ) throws {
        self.options = options
        self.emitter = emitter
        self.runtime = runtime
        self.privateFiles = privateFiles
        self.runID = runID

        guard MTLCreateSystemDefaultDevice() != nil else {
            throw HostFailure(code: "metal_device_unavailable")
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let logicalSize = CGSize(
            width: Double(options.width) / scale,
            height: Double(options.height) / scale
        )
        surface = MetalSurfaceView(
            pixelWidth: options.width,
            pixelHeight: options.height,
            logicalSize: logicalSize
        )
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: logicalSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SolMetal Compatibility Host"
        window.contentView = surface
        window.contentMinSize = NSSize(width: 320, height: 180)
        window.delegate = windowDelegate
        windowDelegate.onClose = { [weak self] in
            self?.closeRequested = true
        }
        surface.layoutSubtreeIfNeeded()
    }

    func execute(gameURL: URL, dataDirectoryURL: URL) -> Int32 {
        if options.hidden {
            window.orderOut(nil)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        guard let metalLayer = surface.metalLayer else {
            emitter.emit("host.error", ["code": "metal_layer_unavailable"])
            return 2
        }

        emitter.emit("host.ready", [
            "runId": runID,
            "developerOnly": true,
            "requestedBackend": "solmetal"
        ])
        emitter.emit("surface.ready", [
            "width": options.width,
            "height": options.height,
            "pixelFormat": "bgra8unorm"
        ])

        let startResult = runtime.start(
            cocoaView: Unmanaged.passUnretained(surface).toOpaque(),
            metalLayer: Unmanaged.passUnretained(metalLayer).toOpaque(),
            gamePath: gameURL.path,
            dataDirectory: dataDirectoryURL.path,
            width: Int32(options.width),
            height: Int32(options.height)
        )
        emitter.emit("engine.start", ["result": startResult])
        guard startResult == 0 else {
            shutdownAccepted = runtime.shutdown() == 0
            emitter.emit("host.finished", [
                "status": "failed",
                "reason": "engine_start_failed",
                "gracefulStop": shutdownAccepted
            ])
            return 3
        }

        let launchStartedAt = Date()
        while terminationExitCode == nil {
            _ = runtime.pump()
            drainEvents()
            readBenchmarkIfAvailable()

            let now = Date()
            if pendingSignal != 0, stopRequestedAt == nil {
                requestStop(reason: "signal", now: now)
            } else if closeRequested, stopRequestedAt == nil {
                requestStop(reason: "window-close", now: now)
            } else if benchmark?.completed == true, stopRequestedAt == nil {
                requestStop(reason: "benchmark-complete", now: now)
            } else if firstFrameAt == nil,
                      now.timeIntervalSince(launchStartedAt) >= options.firstFrameTimeoutSeconds,
                      stopRequestedAt == nil {
                requestStop(reason: "first-frame-timeout", now: now)
            } else if let firstFrameAt,
                      now.timeIntervalSince(firstFrameAt) >=
                        options.warmupSeconds + options.durationSeconds + 15,
                      stopRequestedAt == nil {
                requestStop(reason: "benchmark-timeout", now: now)
            }

            if let stopRequestedAt,
               now.timeIntervalSince(stopRequestedAt) >= options.stopTimeoutSeconds {
                break
            }
            serviceAppKit()
        }

        if stopRequestedAt == nil {
            shutdownAccepted = runtime.shutdown() == 0
        }
        _ = runtime.pump()
        drainEvents()
        readBenchmarkIfAvailable()
        window.orderOut(nil)

        let benchmarkBackend = benchmark?.canonicalBackend ?? "unattested"
        let attestationStatus: String
        if sawSolMetalLaunchStage && benchmarkBackend == "solmetal" {
            attestationStatus = "attested"
        } else if benchmarkBackend != "unattested" && benchmarkBackend != "solmetal" {
            attestationStatus = "conflict"
        } else {
            attestationStatus = "missing"
        }
        emitter.emit("backend.attestation", [
            "requestedBackend": "solmetal",
            "observedBackend": benchmarkBackend,
            "status": attestationStatus,
            "engineLaunchStage": sawSolMetalLaunchStage,
            "benchmarkReport": benchmark != nil
        ])
        if let benchmark {
            emitter.emit("benchmark.result", benchmark.publicFields)
        } else {
            emitter.emit("benchmark.result", ["status": "missing"])
        }

        let gracefulStop = terminationExitCode != nil && stopCommandAccepted && shutdownAccepted
        let passed = terminationExitCode == 0
            && firstFrameAt != nil
            && benchmark?.completed == true
            && attestationStatus == "attested"
            && gracefulStop
        emitter.emit("host.finished", [
            "status": passed ? "passed" : "failed",
            "engineExitCode": terminationExitCode ?? -1,
            "firstFrame": firstFrameAt != nil,
            "benchmarkCompleted": benchmark?.completed == true,
            "backendAttested": attestationStatus == "attested",
            "gracefulStop": gracefulStop
        ])
        return passed ? 0 : 4
    }

    private func requestStop(reason: String, now: Date) {
        stopRequestedAt = now
        let commandResult = runtime.sendCommand("{\"command\":\"stop\"}")
        stopCommandAccepted = commandResult == 0
        let shutdownResult = runtime.shutdown()
        shutdownAccepted = shutdownResult == 0
        emitter.emit("host.stop-requested", [
            "reason": reason,
            "commandAccepted": stopCommandAccepted,
            "shutdownAccepted": shutdownAccepted
        ])
    }

    private func drainEvents() {
        for _ in 0..<256 {
            guard let data = runtime.readEvent() else { break }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                emitter.emit("engine.event-dropped", ["reason": "invalid-json"])
                continue
            }
            let safe = safeManagedEvent(root)
            emitter.emit("engine.event", ["managed": safe])

            guard let event = root["event"] as? String else { continue }
            if event == "launch.first-frame", firstFrameAt == nil {
                firstFrameAt = Date()
            }
            if event == "launch.progress",
               (root["loadStage"] as? String) == "starting-solmetal-gal" {
                sawSolMetalLaunchStage = true
            }
            if event == "embedded.terminated" {
                terminationExitCode = root["exitCode"] as? Int ?? 1
            }
        }
    }

    private func readBenchmarkIfAvailable() {
        guard benchmark?.completed != true,
              let summary = BenchmarkSummary.read(from: privateFiles.benchmarkURL) else {
            return
        }
        benchmark = summary
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateFiles.benchmarkURL.path
        )
    }

    private func serviceAppKit() {
        let deadline = Date(timeIntervalSinceNow: 1.0 / 240.0)
        while let event = NSApp.nextEvent(
            matching: .any,
            until: Date(),
            inMode: .default,
            dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: deadline)
    }
}

@main
private struct SolMetalCompatibilityHostMain {
    @MainActor
    static func main() {
        let emitter: JSONLineEmitter
        do {
            emitter = try JSONLineEmitter()
        } catch {
            Darwin.exit(2)
        }

        let options: Options
        do {
            options = try Options.parse(
                CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment
            )
        } catch let failure as HostFailure {
            emitter.emit("host.error", ["code": failure.code])
            Darwin.exit(2)
        } catch {
            emitter.emit("host.error", ["code": "argument_parse_failed"])
            Darwin.exit(2)
        }

        if options.mode == .help {
            emitter.emit("host.help", [
                "options": [
                    "--app", "--game", "--data", "--width", "--height",
                    "--warmup", "--duration", "--first-frame-timeout",
                    "--stop-timeout", "--hidden", "--runtime-smoke"
                ],
                "privateEnvironment": ["SOL_PRIVATE_GAME_PATH", "SOL_PRIVATE_DATA_PATH"]
            ])
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()

        do {
            if options.mode == .runtimeSmoke {
                try redirectProcessDiagnosticsToNull()
                let layout = try RuntimeLayout(appURL: options.appURL)
                setenv("SOL_METAL_GAL_BACKEND", "1", 1)
                setenv("SOL_METAL_LIBRARY_PATH", layout.solMetalURL.path, 1)
                _ = try ManagedEmbeddedRuntime(layout: layout)
                guard let device = MTLCreateSystemDefaultDevice() else {
                    throw HostFailure(code: "metal_device_unavailable")
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 1
                let surface = MetalSurfaceView(
                    pixelWidth: options.width,
                    pixelHeight: options.height,
                    logicalSize: CGSize(
                        width: Double(options.width) / scale,
                        height: Double(options.height) / scale
                    )
                )
                guard surface.metalLayer?.device != nil else {
                    throw HostFailure(code: "metal_layer_unavailable")
                }
                emitter.emit("runtime.smoke", [
                    "status": "passed",
                    "managedABI": ["Start", "Pump", "ReadEvent", "SendCommand", "Shutdown"],
                    "metalDeviceAvailable": !device.name.isEmpty,
                    "pathsDisclosed": false
                ])
                return
            }

            guard let gameURL = options.gameURL,
                  FileManager.default.fileExists(atPath: gameURL.path) else {
                throw HostFailure(code: "private_game_unavailable")
            }
            guard let dataDirectoryURL = options.dataDirectoryURL else {
                throw HostFailure(code: "private_data_directory_unavailable")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: dataDirectoryURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw HostFailure(code: "private_data_directory_unavailable")
            }

            let runID = UUID().uuidString.lowercased()
            let privateFiles = try PrivateRunFiles.create(
                in: dataDirectoryURL,
                runID: runID
            )
            try privateFiles.redirectProcessDiagnostics()

            // CoreCLR snapshots the process environment while the embedded
            // runtime is initialized. Configure every renderer and benchmark
            // input before either the managed runtime or the test ABI is
            // loaded, after the private output locations have been created.
            setenv("SOL_METAL_GAL_BACKEND", "1", 1)
            setenv("SOL_BENCHMARK_OUTPUT", privateFiles.benchmarkURL.path, 1)
            setenv("SOL_BENCHMARK_LABEL", "embedded-host-solmetal", 1)
            setenv(
                "SOL_BENCHMARK_WARMUP_SECONDS",
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), options.warmupSeconds),
                1
            )
            setenv(
                "SOL_BENCHMARK_DURATION_SECONDS",
                String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), options.durationSeconds),
                1
            )

            let runtime: EmbeddedRuntime
#if SOL_COMPATIBILITY_HOST_TESTING
            if let testRuntimeURL = options.testRuntimeURL {
                runtime = try DirectTestRuntime(url: testRuntimeURL)
            } else {
                let layout = try RuntimeLayout(appURL: options.appURL)
                setenv("SOL_METAL_LIBRARY_PATH", layout.solMetalURL.path, 1)
                runtime = try ManagedEmbeddedRuntime(layout: layout)
            }
#else
            let layout = try RuntimeLayout(appURL: options.appURL)
            setenv("SOL_METAL_LIBRARY_PATH", layout.solMetalURL.path, 1)
            runtime = try ManagedEmbeddedRuntime(layout: layout)
#endif

            Darwin.signal(SIGINT, compatibilitySignalHandler)
            Darwin.signal(SIGTERM, compatibilitySignalHandler)

            let run = try CompatibilityRun(
                options: options,
                emitter: emitter,
                runtime: runtime,
                privateFiles: privateFiles,
                runID: runID
            )
            Darwin.exit(run.execute(gameURL: gameURL, dataDirectoryURL: dataDirectoryURL))
        } catch let failure as HostFailure {
            emitter.emit("host.error", ["code": failure.code])
            Darwin.exit(2)
        } catch {
            emitter.emit("host.error", ["code": "embedded_host_failed"])
            Darwin.exit(2)
        }
    }
}
