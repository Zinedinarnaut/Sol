import AppKit
import Darwin
import Foundation
import OSLog
import SolDLSM

@MainActor
final class SolEngineEmbeddedRuntime {
    static let shared = SolEngineEmbeddedRuntime()

    private let dlsmDiscoveryLogger = Logger(
        subsystem: "com.solemu.app",
        category: "DLSMDiscovery"
    )
    private let solMetalLogger = Logger(
        subsystem: "com.solemu.app",
        category: "SolMetal"
    )
    private let lifecycleLogger = Logger(
        subsystem: "com.solemu.app",
        category: "EngineLifecycle"
    )
    private var host: ManagedSolEngineHost?
    private var pumpTimer: Timer?
    private var resizeTask: Task<Void, Never>?
    private var launchID: UUID?
    private var onSessionEvent: ((SolEngineNativeEvent) -> Void)?
    private var onTermination: ((Int32) -> Void)?
    private var lastSurfaceSize = CGSize.zero
    private var pendingSurfaceSize: CGSize?
    private weak var activeSurface: NSView?

    var isRunning: Bool {
        guard launchID != nil, let host else { return false }
        return host.isRunning() != 0
    }

    nonisolated static func bundledComponentIsAvailable(in bundle: Bundle = .main) -> Bool {
        ManagedSolEngineHost.requiredURLs(in: bundle).allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func launch(
        surface: NSView,
        gameURL: URL,
        captureGroup: String?,
        dataDirectoryURL: URL,
        onSessionEvent: @escaping (SolEngineNativeEvent) -> Void,
        onTermination: @escaping (Int32) -> Void
    ) throws {
        guard launchID == nil else {
            throw RuntimeError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: gameURL.path) else {
            throw RuntimeError.missingGame(gameURL)
        }

        let host = try host ?? ManagedSolEngineHost()
        self.host = host
        self.onSessionEvent = onSessionEvent
        self.onTermination = onTermination

        let launchID = UUID()
        self.launchID = launchID
        startPump()

        guard let size = SolEngineSurfaceSizing.validatedPixelSize(
            backingPixelSize(for: surface)
        ) else {
            cleanup(launchID: launchID)
            throw RuntimeError.invalidSurfaceSize
        }
        activeSurface = surface
        lastSurfaceSize = size
        guard let renderView = surface as? SolEngineRenderView,
              let metalLayer = renderView.metalLayer else {
            cleanup(launchID: launchID)
            throw RuntimeError.missingMetalLayer
        }
        renderView.onKeyEvent = { [weak self] scancode, pressed in
            self?.sendKeyEvent(scancode: scancode, pressed: pressed)
        }
        renderView.onInputReset = { [weak self] in
            self?.resetInput()
        }
        renderView.dlsmPipeline.beginSession(captureGroup: captureGroup)
        let result = host.start(
            cocoaView: Unmanaged.passUnretained(surface).toOpaque(),
            metalLayer: Unmanaged.passUnretained(metalLayer).toOpaque(),
            dlsmCallback: renderView.isDLSMEnabled
                ? renderView.dlsmPipeline.callbackPointer
                : nil,
            dlsmContext: renderView.isDLSMEnabled
                ? renderView.dlsmCallbackContext
                : nil,
            gamePath: gameURL.path,
            dataDirectory: dataDirectoryURL.path,
            width: Int32(size.width.rounded()),
            height: Int32(size.height.rounded())
        )

        guard result == 0 else {
            renderView.dlsmPipeline.endSession()
            cleanup(launchID: launchID)
            throw RuntimeError.startFailed(result)
        }
    }

    func stop() {
        if let renderView = activeSurface as? SolEngineRenderView {
            // Close the Swift presentation gate before the managed renderer
            // begins destroying the borrowed MoltenVK Metal textures.
            renderView.dlsmPipeline.endSession()
        }
        _ = host?.shutdown()
    }

    func pause() throws {
        try send(.pause)
    }

    func resume() throws {
        try send(.resume)
    }

    func setFullscreen(_ fullscreen: Bool) throws {
        try send(.setFullscreen(fullscreen))
    }

    func toggleFullscreen() throws {
        try send(.toggleFullscreen)
    }

    func setVolume(_ volume: Float) throws {
        try send(.setVolume(volume))
    }

    func setVSync(_ mode: String) throws {
        try send(.setVSync(mode))
    }

    func takeScreenshot() throws {
        try send(.screenshot)
    }

    func scanAmiibo(id: String, useRandomUUID: Bool) throws {
        try send(.scanAmiibo(id: id, useRandomUUID: useRandomUUID))
    }

    func queryState() throws {
        try send(.queryState)
    }

    func respondToDialog(requestID: String, accepted: Bool, value: String?) throws {
        try send(.dialogResponse(requestID: requestID, accepted: accepted, value: value))
    }

    func updateInlineKeyboard(
        requestID: String,
        text: String,
        cursorBegin: Int,
        cursorEnd: Int
    ) throws {
        try send(
            .inlineKeyboardUpdate(
                requestID: requestID,
                text: text,
                cursorBegin: cursorBegin,
                cursorEnd: cursorEnd
            )
        )
    }

    func submitInlineKeyboard(requestID: String, text: String) throws {
        try send(.inlineKeyboardSubmit(requestID: requestID, text: text))
    }

    func cancelInlineKeyboard(requestID: String) throws {
        try send(.inlineKeyboardCancel(requestID: requestID))
    }

    func updateSurfaceSize(for surface: NSView) {
        guard launchID != nil, activeSurface === surface, let host else { return }
        guard let size = SolEngineSurfaceSizing.validatedPixelSize(
            backingPixelSize(for: surface)
        ) else {
            return
        }

        let referenceSize = pendingSurfaceSize ?? lastSurfaceSize
        guard abs(size.width - referenceSize.width) >= 1 ||
              abs(size.height - referenceSize.height) >= 1 else {
            return
        }

        pendingSurfaceSize = size
        resizeTask?.cancel()
        let currentLaunchID = launchID
        resizeTask = Task { @MainActor [weak self, weak host] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }

            guard let self,
                  self.launchID == currentLaunchID,
                  let host,
                  let pendingSurfaceSize = self.pendingSurfaceSize else {
                return
            }

            self.pendingSurfaceSize = nil
            self.lastSurfaceSize = pendingSurfaceSize
            _ = host.resize(
                Int32(pendingSurfaceSize.width.rounded()),
                Int32(pendingSurfaceSize.height.rounded())
            )
        }
    }

    func setHostFullscreenState(_ fullscreen: Bool) {
        guard launchID != nil else { return }
        _ = host?.setHostFullscreen(fullscreen ? 1 : 0)
    }

    private func sendKeyEvent(scancode: Int32, pressed: Bool) {
        guard launchID != nil else { return }
        _ = host?.keyEvent(scancode, pressed ? 1 : 0)
    }

    private func resetInput() {
        guard launchID != nil else { return }
        _ = host?.resetInput()
    }

    private func send(_ command: SolEngineSessionCommand) throws {
        guard launchID != nil, let host else {
            throw RuntimeError.noSession
        }

        let data = try JSONSerialization.data(withJSONObject: command.payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw RuntimeError.invalidCommand
        }

        let result = host.sendCommand(json)
        guard result == 0 else {
            throw RuntimeError.commandFailed(result)
        }
    }

    private func startPump() {
        guard pumpTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pump()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func pump() {
        guard let host else { return }
        _ = host.pump()

        for _ in 0..<128 {
            guard let data = host.readEvent() else { break }

            do {
                let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)
                if event.event == "dlsm.attachment-labels", let message = event.message {
                    dlsmDiscoveryLogger.info("\(message, privacy: .public)")
                }
                if event.event == "solmetal.bootstrap-frame" {
                    let message = event.message ?? "SolMetal bootstrap returned no detail"
                    if event.success == true {
                        solMetalLogger.info("\(message, privacy: .public)")
                    } else {
                        solMetalLogger.error("\(message, privacy: .public)")
                    }
                }
                if event.event == "host.error" {
                    let message = event.message ?? "Sol Engine reported an unknown error"
                    lifecycleLogger.error("\(message, privacy: .public)")
                }
                if event.event == "embedded.memory-reclaimed" {
                    let mebibytes = 1_048_576.0
                    let live = Double(event.managedLiveBytes ?? 0) / mebibytes
                    let heap = Double(event.managedHeapBytes ?? 0) / mebibytes
                    let committed = Double(event.managedCommittedBytes ?? 0) / mebibytes
                    let fragmented = Double(event.managedFragmentedBytes ?? 0) / mebibytes
                    let workingSet = Double(event.processWorkingSetBytes ?? 0) / mebibytes
                    let addressSpaces = event.hvAddressSpaces ?? -1
                    let vcpus = event.hvVcpus ?? -1
                    lifecycleLogger.info(
                        "Post-game memory: live \(live, format: .fixed(precision: 1), privacy: .public) MiB, heap \(heap, format: .fixed(precision: 1), privacy: .public) MiB, committed \(committed, format: .fixed(precision: 1), privacy: .public) MiB, fragmented \(fragmented, format: .fixed(precision: 1), privacy: .public) MiB, working set \(workingSet, format: .fixed(precision: 1), privacy: .public) MiB, HV address spaces \(addressSpaces, privacy: .public), vCPUs \(vcpus, privacy: .public)"
                    )
                }
                onSessionEvent?(event)

                if event.event == "embedded.terminated" {
                    let status = Int32(event.exitCode ?? 1)
                    let finishedLaunchID = launchID
                    let callback = onTermination
                    cleanup(launchID: finishedLaunchID)
                    callback?(status)
                    break
                }
            } catch {
                let text = String(decoding: data, as: UTF8.self)
                let line = ConsoleLine(
                    timestamp: Date(),
                    text: "Could not decode embedded event: \(text)\n",
                    stream: .stderr
                )
                NotificationCenter.default.post(
                    name: .solEngineEmbeddedConsoleLine,
                    object: line
                )
            }
        }
    }

    private func cleanup(launchID: UUID?) {
        guard self.launchID == launchID else { return }
        resizeTask?.cancel()
        resizeTask = nil
        pendingSurfaceSize = nil
        pumpTimer?.invalidate()
        pumpTimer = nil
        _ = host?.resetInput()
        if let renderView = activeSurface as? SolEngineRenderView {
            renderView.dlsmPipeline.endSession()
            renderView.onKeyEvent = nil
            renderView.onInputReset = nil
        }
        self.launchID = nil
        onSessionEvent = nil
        onTermination = nil
        lastSurfaceSize = .zero
        activeSurface = nil
    }

    private func backingPixelSize(for view: NSView) -> CGSize {
        if let renderView = view as? SolEngineRenderView {
            return renderView.surfacePixelSize
        }
        let logicalSize = view.bounds.size
        guard let window = view.window else { return logicalSize }
        return window.convertToBacking(NSRect(origin: .zero, size: logicalSize)).size
    }

    enum RuntimeError: LocalizedError {
        case alreadyRunning
        case missingGame(URL)
        case missingMetalLayer
        case invalidSurfaceSize
        case startFailed(Int32)
        case noSession
        case invalidCommand
        case commandFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Sol Engine is already running in this window"
            case .missingGame(let url):
                return "Game file not found at \(url.path)"
            case .missingMetalLayer:
                return "The native Metal render surface is unavailable"
            case .invalidSurfaceSize:
                return "The native Metal render surface is not ready yet"
            case .startFailed(let code):
                return "The embedded Sol Engine engine could not start (code \(code))"
            case .noSession:
                return "No embedded Sol Engine session is running"
            case .invalidCommand:
                return "Could not encode the Sol Engine command"
            case .commandFailed(let code):
                return "Sol Engine rejected the command (code \(code))"
            }
        }
    }
}

extension Notification.Name {
    static let solEngineEmbeddedConsoleLine = Notification.Name("SolEngineEmbeddedConsoleLine")
}

private final class ManagedSolEngineHost {
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
    private typealias ReadEventFunction = @convention(c) (UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias SendCommandFunction = @convention(c) (UnsafePointer<UInt8>?) -> Int32
    private typealias ResizeFunction = @convention(c) (Int32, Int32) -> Int32
    private typealias SetFullscreenFunction = @convention(c) (Int32) -> Int32
    private typealias KeyEventFunction = @convention(c) (Int32, Int32) -> Int32

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
    private let resizeFunction: ResizeFunction
    private let setFullscreenFunction: SetFullscreenFunction
    private let keyEventFunction: KeyEventFunction
    private let resetInputFunction: NoArgumentFunction
    private let isRunningFunction: NoArgumentFunction
    private let shutdownFunction: NoArgumentFunction

    static func requiredURLs(in bundle: Bundle) -> [URL] {
        guard let resources = bundle.resourceURL else { return [] }
        let managed = resources.appendingPathComponent("SolEngineManaged", isDirectory: true)
        let dotnet = resources.appendingPathComponent("Dotnet", isDirectory: true)
        return [
            managed.appendingPathComponent("Sol.Engine.dll"),
            managed.appendingPathComponent("Sol.Engine.deps.json"),
            managed.appendingPathComponent("Sol.Engine.runtimeconfig.json"),
            dotnet.appendingPathComponent("host/fxr/10.0.9/libhostfxr.dylib"),
            dotnet.appendingPathComponent("shared/Microsoft.NETCore.App/10.0.9/libcoreclr.dylib"),
        ]
    }

    init(bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else {
            throw HostError.missingResources
        }

        let managedDirectory = resources.appendingPathComponent("SolEngineManaged", isDirectory: true)
        let dotnetRoot = resources.appendingPathComponent("Dotnet", isDirectory: true)
        let runtimeConfig = managedDirectory.appendingPathComponent("Sol.Engine.runtimeconfig.json")
        let assembly = managedDirectory.appendingPathComponent("Sol.Engine.dll")
        let hostfxr = dotnetRoot.appendingPathComponent("host/fxr/10.0.9/libhostfxr.dylib")

        for url in Self.requiredURLs(in: bundle) where !FileManager.default.fileExists(atPath: url.path) {
            throw HostError.missingFile(url)
        }

        guard let libraryHandle = dlopen(hostfxr.path, RTLD_NOW | RTLD_LOCAL) else {
            throw HostError.loadLibrary(Self.dynamicLoaderError())
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
        let initializeResult = runtimeConfig.path.withCString { runtimeConfigPath in
            dotnetRoot.path.withCString { dotnetRootPath in
                (Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]).withCString { hostPath in
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
            throw HostError.initializeFailed(initializeResult)
        }
        defer { _ = close(context) }

        var loaderPointer: UnsafeMutableRawPointer?
        let getDelegateResult = getRuntimeDelegate(context, 5, &loaderPointer)
        guard getDelegateResult >= 0, let loaderPointer else {
            throw HostError.runtimeDelegateFailed(getDelegateResult)
        }
        let loadAssembly = unsafeBitCast(loaderPointer, to: LoadAssemblyAndGetFunctionPointer.self)

        startFunction = try Self.loadManagedMethod(
            "Start",
            assembly: assembly.path,
            using: loadAssembly,
            as: StartFunction.self
        )
        pumpFunction = try Self.loadManagedMethod(
            "Pump",
            assembly: assembly.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
        readEventFunction = try Self.loadManagedMethod(
            "ReadEvent",
            assembly: assembly.path,
            using: loadAssembly,
            as: ReadEventFunction.self
        )
        sendCommandFunction = try Self.loadManagedMethod(
            "SendCommand",
            assembly: assembly.path,
            using: loadAssembly,
            as: SendCommandFunction.self
        )
        resizeFunction = try Self.loadManagedMethod(
            "Resize",
            assembly: assembly.path,
            using: loadAssembly,
            as: ResizeFunction.self
        )
        setFullscreenFunction = try Self.loadManagedMethod(
            "SetHostFullscreen",
            assembly: assembly.path,
            using: loadAssembly,
            as: SetFullscreenFunction.self
        )
        keyEventFunction = try Self.loadManagedMethod(
            "KeyEvent",
            assembly: assembly.path,
            using: loadAssembly,
            as: KeyEventFunction.self
        )
        resetInputFunction = try Self.loadManagedMethod(
            "ResetInput",
            assembly: assembly.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
        isRunningFunction = try Self.loadManagedMethod(
            "IsRunning",
            assembly: assembly.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
        shutdownFunction = try Self.loadManagedMethod(
            "Shutdown",
            assembly: assembly.path,
            using: loadAssembly,
            as: NoArgumentFunction.self
        )
    }

    func start(
        cocoaView: UnsafeMutableRawPointer,
        metalLayer: UnsafeMutableRawPointer,
        dlsmCallback: UnsafeMutableRawPointer?,
        dlsmContext: UnsafeMutableRawPointer?,
        gamePath: String,
        dataDirectory: String,
        width: Int32,
        height: Int32
    ) -> Int32 {
        gamePath.withCString { gamePathPointer in
            dataDirectory.withCString { dataDirectoryPointer in
                startFunction(
                    cocoaView,
                    metalLayer,
                    dlsmCallback,
                    dlsmContext,
                    UnsafeRawPointer(gamePathPointer).assumingMemoryBound(to: UInt8.self),
                    UnsafeRawPointer(dataDirectoryPointer).assumingMemoryBound(to: UInt8.self),
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
                guard required <= 4 * 1024 * 1024 else { return nil }
                buffer = [UInt8](repeating: 0, count: required)
                continue
            }

            return Data(buffer.prefix(Int(result)))
        }
    }

    func sendCommand(_ json: String) -> Int32 {
        json.withCString {
            sendCommandFunction(UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self))
        }
    }

    func resize(_ width: Int32, _ height: Int32) -> Int32 {
        resizeFunction(width, height)
    }

    func setHostFullscreen(_ fullscreen: Int32) -> Int32 {
        setFullscreenFunction(fullscreen)
    }

    func keyEvent(_ scancode: Int32, _ pressed: Int32) -> Int32 {
        keyEventFunction(scancode, pressed)
    }

    func resetInput() -> Int32 {
        resetInputFunction()
    }

    func isRunning() -> Int32 {
        isRunningFunction()
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
            throw HostError.managedMethodFailed(method, result)
        }
        return unsafeBitCast(functionPointer, to: type)
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw HostError.missingSymbol(name)
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func dynamicLoaderError() -> String {
        guard let error = dlerror() else { return "Unknown dynamic loader error" }
        return String(cString: error)
    }

    enum HostError: LocalizedError {
        case missingResources
        case missingFile(URL)
        case loadLibrary(String)
        case missingSymbol(String)
        case initializeFailed(Int32)
        case runtimeDelegateFailed(Int32)
        case managedMethodFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .missingResources:
                return "The application bundle has no Resources directory"
            case .missingFile(let url):
                return "The embedded runtime is missing \(url.lastPathComponent)"
            case .loadLibrary(let message):
                return "Could not load .NET host: \(message)"
            case .missingSymbol(let name):
                return "The .NET host is missing \(name)"
            case .initializeFailed(let code):
                return "The .NET runtime could not initialize (code \(code))"
            case .runtimeDelegateFailed(let code):
                return "The .NET component loader could not initialize (code \(code))"
            case .managedMethodFailed(let method, let code):
                return "Could not load the Sol Engine \(method) entry point (code \(code))"
            }
        }
    }
}
