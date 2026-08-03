import Foundation

enum SolEngineSessionPhase: String, Equatable {
    case idle
    case launching
    case running
    case paused
    case stopping

    var isActive: Bool {
        self != .idle
    }
}

struct SolEngineSessionSnapshot: Equatable {
    var phase: SolEngineSessionPhase = .idle
    var isFullscreen = false
    var volume: Float = 1
    var title: String?
    var titleID: String?
    var capabilities: Set<String> = []

    var isPaused: Bool {
        phase == .paused
    }
}

struct SolEngineLaunchActivity: Equatable {
    var stage = "preparing-surface"
    var message = "Preparing the native Metal surface"
    var current: Int?
    var total: Int?
    var completedMessages: [String] = []
    var hasPresentedFrame = false

    var isVisible: Bool {
        !hasPresentedFrame
    }

    var progressFraction: Double? {
        guard let current,
              let total,
              total > 0 else {
            return nil
        }
        return min(max(Double(current) / Double(total), 0), 1)
    }

    var progressDetail: String? {
        guard let current,
              let total,
              total > 0 else {
            return nil
        }
        return "\(min(max(current, 0), total)) of \(total)"
    }

    mutating func update(
        stage: String,
        message: String,
        current: Int? = nil,
        total: Int? = nil
    ) {
        if self.message != message,
           !self.message.isEmpty,
           !completedMessages.contains(self.message) {
            completedMessages.append(self.message)
            completedMessages = Array(completedMessages.suffix(3))
        }
        self.stage = stage
        self.message = message
        self.current = current
        self.total = total
    }

    mutating func markFirstFramePresented() {
        if !message.isEmpty, !completedMessages.contains(message) {
            completedMessages.append(message)
            completedMessages = Array(completedMessages.suffix(3))
        }
        stage = "first-frame"
        message = "First Metal frame presented"
        current = nil
        total = nil
        hasPresentedFrame = true
    }
}

struct DLSMProviderStatus: Equatable {
    var stage = "waiting"
    var generation = 0
    var sceneReady = false
    var depthReady = false
    var motionReady = false
    var rawExportReady = false
    var exportReady = false
    var sceneCut = false
    var sceneLabel = "unresolved"
    var depthLabel = "unresolved"
    var motionLabel = "unresolved"
    var depthFormat = "Unknown"
    var motionFormat = "Unknown"
    var width = 0
    var height = 0

    var stageTitle: String {
        switch stage {
        case "scene-candidate-ready": return "Scene Candidate Ready"
        case "depth-candidate-ready": return "Depth Candidate Ready"
        case "attachment-candidates-ready": return "Attachment Candidates Ready"
        case "raw-export-ready": return "Raw Metal Export Ready"
        case "export-ready": return "Canonical Export Ready"
        case "discovering": return "Discovering Attachments"
        default: return "Waiting for a Game"
        }
    }

    mutating func merge(_ event: SolEngineNativeEvent) {
        guard event.event == "dlsm.provider-readiness" else { return }

        let incomingGeneration = event.providerGeneration ?? generation
        if event.sceneCut == true || incomingGeneration != generation {
            self = DLSMProviderStatus(
                stage: "discovering",
                generation: incomingGeneration
            )
        }

        generation = incomingGeneration
        sceneCut = event.sceneCut ?? false
        (sceneReady, sceneLabel) = Self.mergedCandidate(
            ready: sceneReady,
            label: sceneLabel,
            incomingReady: event.sceneReady,
            incomingLabel: event.sceneLabel
        )
        (depthReady, depthLabel) = Self.mergedCandidate(
            ready: depthReady,
            label: depthLabel,
            incomingReady: event.depthReady,
            incomingLabel: event.depthLabel
        )
        (motionReady, motionLabel) = Self.mergedCandidate(
            ready: motionReady,
            label: motionLabel,
            incomingReady: event.motionReady,
            incomingLabel: event.motionLabel
        )

        if let format = event.depthFormat, format != "Unknown" {
            depthFormat = format
        }
        if let format = event.motionFormat, format != "Unknown" {
            motionFormat = format
        }
        if let width = event.width, width > 0 {
            self.width = width
        }
        if let height = event.height, height > 0 {
            self.height = height
        }

        rawExportReady = rawExportReady || (event.rawExportReady ?? false)
        exportReady = exportReady || (event.exportReady ?? false)
        stage = exportReady
            ? "export-ready"
            : rawExportReady
                ? "raw-export-ready"
            : motionReady
                ? "attachment-candidates-ready"
                : depthReady
                    ? "depth-candidate-ready"
                    : sceneReady
                        ? "scene-candidate-ready"
                        : event.providerStage ?? "discovering"
    }

    private static func mergedCandidate(
        ready currentReady: Bool,
        label currentLabel: String,
        incomingReady: Bool?,
        incomingLabel: String?
    ) -> (Bool, String) {
        if incomingReady == true {
            return (true, incomingLabel ?? currentLabel)
        }
        if !currentReady, let incomingLabel {
            return (false, incomingLabel)
        }
        return (currentReady, currentLabel)
    }
}

struct SolEngineDialogOption: Decodable, Equatable {
    let value: String
    let label: String
}

struct SolEngineNativeEvent: Decodable, Equatable {
    let protocolVersion: Int
    let event: String
    let phase: String?
    let paused: Bool?
    let fullscreen: Bool?
    let volume: Float?
    let vsyncMode: String?
    let title: String?
    let titleID: String?
    let message: String?
    let path: String?
    let command: String?
    let operation: String?
    let firmwareVersion: String?
    let dataDirectory: String?
    let hasProdKeys: Bool?
    let success: Bool?
    let exitCode: Int?
    let requestID: String?
    let dialogKind: String?
    let inputMode: String?
    let defaultValue: String?
    let minimumLength: Int?
    let maximumLength: Int?
    let inputID: String?
    let inputName: String?
    let inputKind: String?
    let playerIndex: String?
    let assignedPlayers: [String]?
    let usesEastConfirmButton: Bool?
    let isConnected: Bool?
    let bindings: [String: String]?
    let bindingName: String?
    let bindingValue: String?
    let profileID: String?
    let profileName: String?
    let profileImageBase64: String?
    let isDefault: Bool?
    let count: Int?
    let dlcCount: Int?
    let updateCount: Int?
    let directoryCount: Int?
    let addedCount: Int?
    let removedCount: Int?
    let providerStage: String?
    let providerGeneration: Int?
    let sceneReady: Bool?
    let depthReady: Bool?
    let motionReady: Bool?
    let rawExportReady: Bool?
    let exportReady: Bool?
    let sceneCut: Bool?
    let sceneLabel: String?
    let depthLabel: String?
    let motionLabel: String?
    let depthFormat: String?
    let motionFormat: String?
    let width: Int?
    let height: Int?
    let loadStage: String?
    let progressCurrent: Int?
    let progressTotal: Int?
    let playtimeSeconds: Double?
    let lastPlayedUtc: String?
    let options: [SolEngineDialogOption]?
    let buttons: [String]?
    let capabilities: [String]?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case event
        case phase
        case paused
        case fullscreen
        case volume
        case vsyncMode
        case title
        case titleID = "titleId"
        case message
        case path
        case command
        case operation
        case firmwareVersion
        case dataDirectory
        case hasProdKeys
        case success
        case exitCode
        case requestID = "requestId"
        case dialogKind
        case inputMode
        case defaultValue
        case minimumLength
        case maximumLength
        case inputID = "inputId"
        case inputName
        case inputKind
        case playerIndex
        case assignedPlayers
        case usesEastConfirmButton
        case isConnected
        case bindings
        case bindingName
        case bindingValue
        case profileID = "profileId"
        case profileName
        case profileImageBase64
        case isDefault
        case count
        case dlcCount
        case updateCount
        case directoryCount
        case addedCount
        case removedCount
        case providerStage
        case providerGeneration
        case sceneReady
        case depthReady
        case motionReady
        case rawExportReady
        case exportReady
        case sceneCut
        case sceneLabel
        case depthLabel
        case motionLabel
        case depthFormat
        case motionFormat
        case width
        case height
        case loadStage
        case progressCurrent
        case progressTotal
        case playtimeSeconds
        case lastPlayedUtc
        case options
        case buttons
        case capabilities
    }
}

enum SolEngineSessionCommand {
    case queryState
    case pause
    case resume
    case stop
    case setFullscreen(Bool)
    case toggleFullscreen
    case setVolume(Float)
    case setVSync(String)
    case screenshot
    case scanAmiibo(id: String, useRandomUUID: Bool)
    case dialogResponse(requestID: String, accepted: Bool, value: String?)

    var payload: [String: Any] {
        switch self {
        case .queryState:
            return ["protocol": 1, "command": "query-state"]
        case .pause:
            return ["protocol": 1, "command": "pause"]
        case .resume:
            return ["protocol": 1, "command": "resume"]
        case .stop:
            return ["protocol": 1, "command": "stop"]
        case .setFullscreen(let fullscreen):
            return ["protocol": 1, "command": "set-fullscreen", "value": fullscreen]
        case .toggleFullscreen:
            return ["protocol": 1, "command": "toggle-fullscreen"]
        case .setVolume(let volume):
            return ["protocol": 1, "command": "set-volume", "value": min(max(volume, 0), 1)]
        case .setVSync(let mode):
            return ["protocol": 1, "command": "set-vsync", "value": mode]
        case .screenshot:
            return ["protocol": 1, "command": "screenshot"]
        case .scanAmiibo(let id, let useRandomUUID):
            return [
                "protocol": 1,
                "command": "scan-amiibo",
                "amiiboId": id,
                "useRandomUuid": useRandomUUID,
            ]
        case .dialogResponse(let requestID, let accepted, let value):
            var payload: [String: Any] = [
                "protocol": 1,
                "command": "dialog-response",
                "requestId": requestID,
                "accepted": accepted,
            ]
            if let value {
                payload["value"] = value
            }
            return payload
        }
    }
}
