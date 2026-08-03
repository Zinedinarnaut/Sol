import Foundation
import Darwin

@MainActor
final class SolEngineProcessService {
    private static let nativeProtocolPrefix = "@@SOL_ENGINE@@"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var launchID: UUID?
    private var stopFallbackTask: Task<Void, Never>?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func launch(
        executableURL: URL,
        gamePath: URL,
        onOutput: @escaping @MainActor (ConsoleLine) -> Void,
        onSessionEvent: @escaping @MainActor (SolEngineNativeEvent) -> Void = { _ in },
        onTermination: @escaping @MainActor (Int32) -> Void
    ) throws {
        guard process == nil else {
            throw ProcessError.alreadyRunning
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessError.invalidExecutable(executableURL)
        }
        guard FileManager.default.fileExists(atPath: gamePath.path) else {
            throw ProcessError.missingGame(gamePath)
        }

        let process = Process()
        let launchID = UUID()
        process.executableURL = executableURL
        process.arguments = ["--use-main-config", gamePath.path]
        process.qualityOfService = .userInteractive

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutFramer = OutputFramer(
            stream: .stdout,
            protocolPrefix: Self.nativeProtocolPrefix,
            onOutput: onOutput,
            onSessionEvent: onSessionEvent
        )
        let stderrFramer = OutputFramer(
            stream: .stderr,
            protocolPrefix: Self.nativeProtocolPrefix,
            onOutput: onOutput,
            onSessionEvent: onSessionEvent
        )
        stdout.fileHandleForReading.readabilityHandler = Self.outputHandler(framer: stdoutFramer)
        stderr.fileHandleForReading.readabilityHandler = Self.outputHandler(framer: stderrFramer)
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor in
                self?.handleTermination(launchID: launchID, status: status, callback: onTermination)
            }
        }

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.launchID = launchID

        do {
            try process.run()
        } catch {
            cleanup(launchID: launchID)
            throw error
        }
        elevatePriority(for: process)
    }

    func stop() {
        guard let process, process.isRunning else { return }
        try? send(.stop)
        scheduleStopFallback(for: process, launchID: launchID)
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

    func queryState() throws {
        try send(.queryState)
    }

    func respondToDialog(requestID: String, accepted: Bool, value: String?) throws {
        try send(.dialogResponse(requestID: requestID, accepted: accepted, value: value))
    }

    private func send(_ command: SolEngineSessionCommand) throws {
        guard let process, process.isRunning, let stdinPipe else {
            throw ProcessError.noNativeSession
        }

        let data = try JSONSerialization.data(withJSONObject: command.payload, options: [.sortedKeys])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private static func outputHandler(framer: OutputFramer) -> @Sendable (FileHandle) -> Void {
        { handle in
            let data = handle.availableData
            if data.isEmpty {
                framer.finish()
            } else {
                framer.consume(data)
            }
        }
    }

    private func handleTermination(
        launchID: UUID,
        status: Int32,
        callback: @MainActor (Int32) -> Void
    ) {
        guard self.launchID == launchID else { return }
        cleanup(launchID: launchID)
        callback(status)
    }

    private func cleanup(launchID: UUID) {
        guard self.launchID == launchID else { return }
        stopFallbackTask?.cancel()
        stopFallbackTask = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminationHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        self.launchID = nil
    }

    private func elevatePriority(for process: Process) {
        let pid = process.processIdentifier
        _ = setpriority(PRIO_PROCESS, id_t(pid), -5)
    }

    private func scheduleStopFallback(for process: Process, launchID: UUID?) {
        stopFallbackTask?.cancel()
        stopFallbackTask = Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(for: .seconds(3))
            guard let self,
                  self.launchID == launchID,
                  let process,
                  process.isRunning else { return }
            process.terminate()
        }
    }

    private enum ProcessError: LocalizedError {
        case alreadyRunning
        case invalidExecutable(URL)
        case missingGame(URL)
        case noNativeSession

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Sol Engine is already running"
            case .invalidExecutable(let url):
                return "Sol Engine is not executable at \(url.path)"
            case .missingGame(let url):
                return "Game file not found at \(url.path)"
            case .noNativeSession:
                return "No native Sol Engine session is running"
            }
        }
    }
}

private final class OutputFramer: @unchecked Sendable {
    private let stream: ConsoleStream
    private let protocolPrefix: String
    private let onOutput: @MainActor (ConsoleLine) -> Void
    private let onSessionEvent: @MainActor (SolEngineNativeEvent) -> Void
    private let lock = NSLock()
    private var buffer = Data()

    init(
        stream: ConsoleStream,
        protocolPrefix: String,
        onOutput: @escaping @MainActor (ConsoleLine) -> Void,
        onSessionEvent: @escaping @MainActor (SolEngineNativeEvent) -> Void
    ) {
        self.stream = stream
        self.protocolPrefix = protocolPrefix
        self.onOutput = onOutput
        self.onSessionEvent = onSessionEvent
    }

    func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let lines = drainCompleteLines()
        lock.unlock()

        lines.forEach(publish)
    }

    func finish() {
        lock.lock()
        let trailing = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if !trailing.isEmpty {
            publish(String(decoding: trailing, as: UTF8.self))
        }
    }

    private func drainCompleteLines() -> [String] {
        var lines: [String] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }

        return lines
    }

    private func publish(_ line: String) {
        if line.hasPrefix(protocolPrefix) {
            let json = String(line.dropFirst(protocolPrefix.count))
            if let data = json.data(using: .utf8),
               let event = try? JSONDecoder().decode(SolEngineNativeEvent.self, from: data) {
                Task { @MainActor in
                    onSessionEvent(event)
                }
                return
            }
        }

        let consoleLine = ConsoleLine(timestamp: Date(), text: line + "\n", stream: stream)
        Task { @MainActor in
            onOutput(consoleLine)
        }
    }
}
