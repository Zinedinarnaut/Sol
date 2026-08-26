import Foundation

struct SolEngineBackendStatus: Equatable {
    var hasProdKeys = false
    var firmwareVersion: String?
    var dataDirectory: String?
    var dlcCount = 0
    var updateCount = 0
    var contentDirectoryCount = 0
    var message: String?
    var errorMessage: String?
}

struct SolEngineInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: Kind
    let usesEastConfirmButton: Bool
    let isConnected: Bool
    let assignedPlayers: [SolEnginePlayerIndex]

    func isAssigned(to player: SolEnginePlayerIndex) -> Bool {
        assignedPlayers.contains(player)
    }

    var assignmentTitle: String? {
        guard !assignedPlayers.isEmpty else { return nil }
        return assignedPlayers.map(\.title).joined(separator: ", ")
    }

    enum Kind: String, Hashable {
        case keyboard
        case controller

        var title: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .controller: return "Controller"
            }
        }
    }
}

enum SolEngineInputSelection {
    static func preferredDeviceID(
        in devices: [SolEngineInputDevice],
        for player: SolEnginePlayerIndex,
        matching controllerName: String?,
        currentID: String?,
        preserveCurrent: Bool
    ) -> String? {
        if preserveCurrent,
           let currentID,
           devices.contains(where: { $0.id == currentID }) {
            return currentID
        }

        if let assigned = devices.first(where: { $0.isAssigned(to: player) }) {
            return assigned.id
        }

        if let controllerName {
            let normalizedName = normalize(controllerName)
            if let matching = devices.first(where: {
                $0.kind == .controller && normalize($0.name) == normalizedName
            }) {
                return matching.id
            }
        }

        return devices.first(where: { $0.kind == .controller })?.id
            ?? devices.first?.id
    }

    private static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
    }
}

struct SolEngineProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let imageData: Data?
    let isDefault: Bool
}

enum SolEnginePlayerIndex: String, CaseIterable, Identifiable {
    case player1 = "Player1"
    case player2 = "Player2"
    case player3 = "Player3"
    case player4 = "Player4"
    case player5 = "Player5"
    case player6 = "Player6"
    case player7 = "Player7"
    case player8 = "Player8"
    case handheld = "Handheld"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player1: return "Player 1"
        case .player2: return "Player 2"
        case .player3: return "Player 3"
        case .player4: return "Player 4"
        case .player5: return "Player 5"
        case .player6: return "Player 6"
        case .player7: return "Player 7"
        case .player8: return "Player 8"
        case .handheld: return "Handheld"
        }
    }
}

enum SolEngineBackendOperation {
    case status
    case installKeys(URL)
    case verifyFirmware(URL)
    case installFirmware(URL)
    case scanContent
    case listInputs
    case setInput(deviceID: String, player: SolEnginePlayerIndex)
    case setInputBinding(
        SolEngineLogicalControl,
        SolEnginePhysicalButton,
        player: SolEnginePlayerIndex
    )
    case resetInputBindings(player: SolEnginePlayerIndex)
    case setInputTuning(SolEngineControllerTuning, player: SolEnginePlayerIndex)
    case testInputRumble(player: SolEnginePlayerIndex)
    case listProfiles
    case setProfile(String)
    case createProfile(name: String, imageBase64: String?)
    case renameProfile(id: String, name: String)
    case deleteProfile(id: String)
    case setProfileImage(id: String, imageBase64: String)
    case solMetalStatus

    var arguments: [String] {
        switch self {
        case .status:
            return ["--native-status"]
        case .installKeys(let url):
            return ["--native-install-keys", url.path]
        case .verifyFirmware(let url):
            return ["--native-verify-firmware", url.path]
        case .installFirmware(let url):
            return ["--native-install-firmware", url.path]
        case .scanContent:
            return ["--native-scan-content"]
        case .listInputs:
            return ["--native-list-inputs"]
        case .setInput(let deviceID, let player):
            return [
                "--native-set-input",
                deviceID,
                "--native-player",
                player.rawValue,
            ]
        case .setInputBinding(let control, let button, let player):
            return [
                "--native-set-input-binding",
                control.rawValue,
                "--native-binding",
                button.rawValue,
                "--native-player",
                player.rawValue,
            ]
        case .resetInputBindings(let player):
            return [
                "--native-reset-input-bindings",
                "--native-player",
                player.rawValue,
            ]
        case .setInputTuning(let tuning, let player):
            return [
                "--native-set-input-tuning",
                "--native-player", player.rawValue,
                "--deadzone-left", String(tuning.deadzoneLeft),
                "--deadzone-right", String(tuning.deadzoneRight),
                "--range-left", String(tuning.rangeLeft),
                "--range-right", String(tuning.rangeRight),
                "--trigger-threshold", String(tuning.triggerThreshold),
                "--motion-enabled", String(tuning.motionEnabled),
                "--motion-sensitivity", String(tuning.motionSensitivity),
                "--gyro-deadzone", String(tuning.gyroDeadzone),
                "--rumble-enabled", String(tuning.rumbleEnabled),
                "--strong-rumble", String(tuning.strongRumble),
                "--weak-rumble", String(tuning.weakRumble),
                "--hd-rumble", String(tuning.hdRumble),
                "--led-enabled", String(tuning.ledEnabled),
                "--led-off", String(tuning.ledOff),
                "--led-rainbow", String(tuning.ledRainbow),
                "--led-color", String(tuning.ledColor),
            ]
        case .testInputRumble(let player):
            return [
                "--native-test-input-rumble",
                "--native-player",
                player.rawValue,
            ]
        case .listProfiles:
            return ["--native-list-profiles"]
        case .setProfile(let profileID):
            return ["--native-set-profile", profileID]
        case .createProfile(let name, let imageBase64):
            var arguments = ["--native-create-profile", name]
            if let imageBase64 {
                arguments += ["--native-profile-image-base64", imageBase64]
            }
            return arguments
        case .renameProfile(let id, let name):
            return [
                "--native-rename-profile", id,
                "--native-profile-name", name,
            ]
        case .deleteProfile(let id):
            return ["--native-delete-profile", id]
        case .setProfileImage(let id, let imageBase64):
            return [
                "--native-set-profile-image", id,
                "--native-profile-image-base64", imageBase64,
            ]
        case .solMetalStatus:
            return ["--native-solmetal-status"]
        }
    }

    var requiresAuthoritativeStatusRefresh: Bool {
        switch self {
        case .installKeys, .installFirmware, .scanContent:
            return true
        default:
            return false
        }
    }
}

struct SolEngineBackendService: Sendable {
    func run(
        executableURL: URL,
        dataDirectoryURL: URL,
        operation: SolEngineBackendOperation
    ) async throws -> [SolEngineNativeEvent] {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw BackendError.invalidExecutable
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "--root-data-dir",
            dataDirectoryURL.path,
        ] + operation.arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        try process.run()

        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        let stdoutTask = Task.detached(priority: .utility) {
            stdoutHandle.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrHandle.readDataToEndOfFile()
        }
        let statusTask = Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        let status = await statusTask.value
        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let events = decodeEvents(from: stdoutData)

        guard status == 0 else {
            let backendMessage = events.last(where: { $0.success == false })?.message
            let stderrText = String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError.operationFailed(
                backendMessage ?? (stderrText.isEmpty ? "Sol Engine backend operation failed" : stderrText)
            )
        }

        return events
    }

    private func decodeEvents(from data: Data) -> [SolEngineNativeEvent] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> SolEngineNativeEvent? in
                let value = String(line)
                let prefix = "@@SOL_ENGINE@@"
                guard value.hasPrefix(prefix),
                      let json = String(value.dropFirst(prefix.count)).data(using: .utf8) else {
                    return nil
                }
                return try? JSONDecoder().decode(SolEngineNativeEvent.self, from: json)
            }
    }

    private enum BackendError: LocalizedError {
        case invalidExecutable
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidExecutable:
                return "Bundled Sol Engine engine is missing"
            case .operationFailed(let message):
                return message
            }
        }
    }
}
