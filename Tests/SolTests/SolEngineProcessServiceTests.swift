import Foundation
import XCTest
@testable import Sol

final class SolEngineProcessServiceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testCapturesOutputAndResetsStateAfterTermination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolProcessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executableURL = root.appendingPathComponent("fake-solEngine")
        let script = """
        #!/bin/sh
        printf 'standard output\\n'
        printf 'standard error\\n' >&2
        exit 7
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let gameURL = root.appendingPathComponent("game.nsp")
        try Data([0x01]).write(to: gameURL)

        let terminated = expectation(description: "process terminated")
        var output: [ConsoleLine] = []
        var terminationStatus: Int32?
        let service = SolEngineProcessService()

        try service.launch(
            executableURL: executableURL,
            gamePath: gameURL,
            onOutput: { output.append($0) },
            onTermination: {
                terminationStatus = $0
                terminated.fulfill()
            }
        )

        await fulfillment(of: [terminated], timeout: 5)

        XCTAssertEqual(terminationStatus, 7)
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(output.contains { $0.stream == .stdout && $0.text.contains("standard output") })
        XCTAssertTrue(output.contains { $0.stream == .stderr && $0.text.contains("standard error") })
    }

    @MainActor
    func testRejectsASecondLaunchWhileFirstProcessIsRunning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolProcessTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let executableURL = root.appendingPathComponent("fake-solEngine")
        try Data("#!/bin/sh\nsleep 2\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let gameURL = root.appendingPathComponent("game.nsp")
        try Data([0x01]).write(to: gameURL)
        let service = SolEngineProcessService()
        let terminated = expectation(description: "stopped process terminated")
        try service.launch(
            executableURL: executableURL,
            gamePath: gameURL,
            onOutput: { _ in },
            onTermination: { _ in terminated.fulfill() }
        )

        XCTAssertThrowsError(
            try service.launch(
                executableURL: executableURL,
                gamePath: gameURL,
                onOutput: { _ in },
                onTermination: { _ in }
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Sol Engine is already running")
        }

        service.stop()
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertFalse(service.isRunning)
    }

    @MainActor
    func testNativeLaunchSkipsAvaloniaAndUsesMainConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolProcessArguments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let executableURL = root.appendingPathComponent("fake-solEngine")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let gameURL = root.appendingPathComponent("game.nsp")
        try Data([0x01]).write(to: gameURL)
        let terminated = expectation(description: "native launch terminated")
        let service = SolEngineProcessService()

        try service.launch(
            executableURL: executableURL,
            gamePath: gameURL,
            onOutput: { _ in },
            onTermination: { _ in terminated.fulfill() }
        )

        await fulfillment(of: [terminated], timeout: 3)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(arguments, ["--use-main-config", gameURL.path])
    }

    @MainActor
    func testSendsNativeCommandsAndDecodesSessionEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolSessionProtocol-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let commandURL = root.appendingPathComponent("command.json")
        let executableURL = root.appendingPathComponent("fake-solEngine")
        let event = #"@@SOL_ENGINE@@{"protocol":1,"event":"session.state","phase":"paused","paused":true,"fullscreen":true,"volume":0.5,"title":"Native Test"}"#
        let script = """
        #!/bin/sh
        IFS= read -r command
        printf '%s' "$command" > "\(commandURL.path)"
        printf '%s\\n' '\(event)'
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let gameURL = root.appendingPathComponent("game.nsp")
        try Data([0x01]).write(to: gameURL)

        let receivedEvent = expectation(description: "session event received")
        let terminated = expectation(description: "protocol process terminated")
        let service = SolEngineProcessService()
        var sessionEvent: SolEngineNativeEvent?

        try service.launch(
            executableURL: executableURL,
            gamePath: gameURL,
            onOutput: { _ in },
            onSessionEvent: {
                sessionEvent = $0
                receivedEvent.fulfill()
            },
            onTermination: { _ in
                terminated.fulfill()
            }
        )
        try service.pause()

        await fulfillment(of: [receivedEvent, terminated], timeout: 3)

        let commandData = try Data(contentsOf: commandURL)
        let command = try XCTUnwrap(
            JSONSerialization.jsonObject(with: commandData) as? [String: Any]
        )
        XCTAssertEqual(command["protocol"] as? Int, 1)
        XCTAssertEqual(command["command"] as? String, "pause")
        XCTAssertEqual(sessionEvent?.phase, "paused")
        XCTAssertEqual(sessionEvent?.paused, true)
        XCTAssertEqual(sessionEvent?.fullscreen, true)
        XCTAssertEqual(sessionEvent?.volume, 0.5)
        XCTAssertEqual(sessionEvent?.title, "Native Test")
    }

    func testDialogResponsePayloadPreservesRequestAndText() throws {
        let payload = SolEngineSessionCommand.dialogResponse(
            requestID: "dialog-123",
            accepted: true,
            value: "Player"
        ).payload

        XCTAssertEqual(payload["protocol"] as? Int, 1)
        XCTAssertEqual(payload["command"] as? String, "dialog-response")
        XCTAssertEqual(payload["requestId"] as? String, "dialog-123")
        XCTAssertEqual(payload["accepted"] as? Bool, true)
        XCTAssertEqual(payload["value"] as? String, "Player")
    }

    func testDLSMAttachmentLabelEventDecodesDiagnosticMessage() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "dlsm.attachment-labels",
              "message": "DLSM attachment labels f120: depth=likely; motion=unresolved"
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)

        XCTAssertEqual(event.event, "dlsm.attachment-labels")
        XCTAssertEqual(
            event.message,
            "DLSM attachment labels f120: depth=likely; motion=unresolved"
        )
    }

    func testPlaytimeUpdateDecodesForImmediateLibraryRefresh() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "playtime.updated",
              "titleId": "0100152000022000",
              "playtimeSeconds": 74.25,
              "lastPlayedUtc": "2026-07-28T06:40:00.0000000Z"
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)

        XCTAssertEqual(event.event, "playtime.updated")
        XCTAssertEqual(event.titleID, "0100152000022000")
        XCTAssertEqual(event.playtimeSeconds, 74.25)
        XCTAssertEqual(event.lastPlayedUtc, "2026-07-28T06:40:00.0000000Z")
    }

    func testDLSMProviderReadinessDecodesWithoutUnlockingExport() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "dlsm.provider-readiness",
              "providerStage": "depth-candidate-ready",
              "providerGeneration": 2,
              "sceneReady": true,
              "depthReady": true,
              "motionReady": false,
              "exportReady": false,
              "sceneCut": true,
              "sceneLabel": "stable",
              "depthLabel": "stable",
              "motionLabel": "unresolved",
              "depthFormat": "D32Float",
              "motionFormat": "Unknown",
              "width": 1920,
              "height": 1080
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)

        XCTAssertEqual(event.providerStage, "depth-candidate-ready")
        XCTAssertEqual(event.providerGeneration, 2)
        XCTAssertEqual(event.sceneReady, true)
        XCTAssertEqual(event.depthReady, true)
        XCTAssertEqual(event.motionReady, false)
        XCTAssertEqual(event.exportReady, false)
        XCTAssertEqual(event.sceneCut, true)
        XCTAssertEqual(event.depthFormat, "D32Float")
        XCTAssertEqual(event.width, 1920)
        XCTAssertEqual(event.height, 1080)
    }

    func testDLSMRawMetalExportDoesNotUnlockCanonicalTemporalInputs() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "dlsm.provider-readiness",
              "providerStage": "raw-export-ready",
              "providerGeneration": 3,
              "sceneReady": true,
              "depthReady": true,
              "motionReady": true,
              "rawExportReady": true,
              "exportReady": false,
              "sceneCut": false,
              "sceneLabel": "stable",
              "depthLabel": "stable",
              "motionLabel": "stable"
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)
        var status = DLSMProviderStatus(stage: "discovering")
        status.merge(event)

        XCTAssertTrue(status.rawExportReady)
        XCTAssertFalse(status.exportReady)
        XCTAssertEqual(status.stage, "raw-export-ready")
        XCTAssertEqual(status.stageTitle, "Raw Metal Export Ready")
    }

    func testDLSMProviderStatusKeepsValidatedLabelsWithinOneScene() throws {
        var status = DLSMProviderStatus(stage: "discovering")

        status.merge(
            try decodeProviderEvent(
                stage: "depth-candidate-ready",
                generation: 0,
                sceneReady: true,
                depthReady: true,
                sceneCut: false,
                sceneLabel: "stable",
                depthLabel: "stable",
                depthFormat: "D32Float"
            )
        )
        status.merge(
            try decodeProviderEvent(
                stage: "discovering",
                generation: 0,
                sceneReady: false,
                depthReady: false,
                sceneCut: false,
                sceneLabel: "unresolved",
                depthLabel: "unresolved",
                depthFormat: "Unknown"
            )
        )

        XCTAssertTrue(status.sceneReady)
        XCTAssertTrue(status.depthReady)
        XCTAssertEqual(status.stage, "depth-candidate-ready")
        XCTAssertEqual(status.sceneLabel, "stable")
        XCTAssertEqual(status.depthLabel, "stable")
        XCTAssertEqual(status.depthFormat, "D32Float")
    }

    func testDLSMProviderStatusResetsLabelsAfterSceneCut() throws {
        var status = DLSMProviderStatus(
            stage: "depth-candidate-ready",
            generation: 0,
            sceneReady: true,
            depthReady: true,
            sceneLabel: "stable",
            depthLabel: "stable",
            depthFormat: "D32Float",
            width: 1920,
            height: 1080
        )

        status.merge(
            try decodeProviderEvent(
                stage: "discovering",
                generation: 1,
                sceneReady: false,
                depthReady: false,
                sceneCut: true,
                sceneLabel: "unresolved",
                depthLabel: "unresolved",
                depthFormat: "Unknown"
            )
        )

        XCTAssertEqual(status.generation, 1)
        XCTAssertFalse(status.sceneReady)
        XCTAssertFalse(status.depthReady)
        XCTAssertEqual(status.stage, "discovering")
        XCTAssertEqual(status.depthFormat, "Unknown")
        XCTAssertEqual(status.width, 0)
        XCTAssertEqual(status.height, 0)
    }

    func testChoiceDialogEventDecodesNativeProfileOptions() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "dialog.request",
              "requestId": "profile-123",
              "dialogKind": "choice",
              "defaultValue": "00000000000000010000000000000000",
              "options": [
                {
                  "value": "00000000000000010000000000000000",
                  "label": "RyuPlayer"
                },
                {
                  "value": "00000000000000000000000000000080",
                  "label": "Guest"
                }
              ],
              "buttons": ["Choose", "Cancel"]
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)

        XCTAssertEqual(event.requestID, "profile-123")
        XCTAssertEqual(event.dialogKind, "choice")
        XCTAssertEqual(event.options?.map(\.label), ["RyuPlayer", "Guest"])
        XCTAssertEqual(
            event.options?.last?.value,
            "00000000000000000000000000000080"
        )
    }

    func testProfileItemDecodesForNativeProfileMenu() throws {
        let data = Data(
            #"""
            {
              "protocol": 1,
              "event": "profile.item",
              "profileId": "00000000000000010000000000000000",
              "profileName": "Player",
              "profileImageBase64": "AQID",
              "isDefault": true
            }
            """#.utf8
        )

        let event = try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)

        XCTAssertEqual(event.profileName, "Player")
        XCTAssertEqual(event.profileImageBase64, "AQID")
        XCTAssertEqual(event.isDefault, true)
    }

    private func decodeProviderEvent(
        stage: String,
        generation: Int,
        sceneReady: Bool,
        depthReady: Bool,
        sceneCut: Bool,
        sceneLabel: String,
        depthLabel: String,
        depthFormat: String
    ) throws -> SolEngineNativeEvent {
        let payload: [String: Any] = [
            "protocol": 1,
            "event": "dlsm.provider-readiness",
            "providerStage": stage,
            "providerGeneration": generation,
            "sceneReady": sceneReady,
            "depthReady": depthReady,
            "motionReady": false,
            "exportReady": false,
            "sceneCut": sceneCut,
            "sceneLabel": sceneLabel,
            "depthLabel": depthLabel,
            "motionLabel": "unresolved",
            "depthFormat": depthFormat,
            "motionFormat": "Unknown",
            "width": sceneReady ? 1920 : 0,
            "height": sceneReady ? 1080 : 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SolEngineNativeEvent.self, from: data)
    }
}
