import Foundation
import XCTest
@testable import Sol

final class SolEngineBackendServiceTests: XCTestCase, @unchecked Sendable {
    func testRunsStatusThroughBundledBackendProtocol() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SolBackendService-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let executableURL = root.appendingPathComponent("fake-solEngine")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        printf '%s\\n' '@@SOL_ENGINE@@{"protocol":1,"event":"backend.status","hasProdKeys":true,"firmwareVersion":"20.1.0","dataDirectory":"\(root.path)"}'
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let events = try await SolEngineBackendService().run(
            executableURL: executableURL,
            dataDirectoryURL: root,
            operation: .status
        )

        let status = try XCTUnwrap(events.first(where: { $0.event == "backend.status" }))
        XCTAssertEqual(status.hasProdKeys, true)
        XCTAssertEqual(status.firmwareVersion, "20.1.0")
        XCTAssertEqual(status.dataDirectory, root.path)

        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(arguments, ["--root-data-dir", root.path, "--native-status"])
    }

    func testPlayerInputOperationUsesNativeBackendArguments() {
        XCTAssertEqual(
            SolEngineBackendOperation.setInput(
                deviceID: "0-controller-guid",
                player: .player2
            ).arguments,
            [
                "--native-set-input",
                "0-controller-guid",
                "--native-player",
                "Player2",
            ]
        )
        XCTAssertEqual(SolEngineBackendOperation.listInputs.arguments, ["--native-list-inputs"])
        XCTAssertEqual(
            SolEngineBackendOperation.setInputBinding(
                .buttonA,
                .b,
                player: .player1
            ).arguments,
            [
                "--native-set-input-binding",
                "buttonA",
                "--native-binding",
                "B",
                "--native-player",
                "Player1",
            ]
        )
        XCTAssertEqual(
            SolEngineBackendOperation.resetInputBindings(player: .player2).arguments,
            [
                "--native-reset-input-bindings",
                "--native-player",
                "Player2",
            ]
        )
        let tuning = SolEngineControllerTuning(
            deadzoneLeft: 0.12,
            deadzoneRight: 0.14,
            rangeLeft: 1,
            rangeRight: 0.95,
            triggerThreshold: 0.35,
            motionEnabled: true,
            motionSensitivity: 125,
            gyroDeadzone: 0.8,
            rumbleEnabled: true,
            strongRumble: 0.9,
            weakRumble: 0.7,
            hdRumble: true,
            ledEnabled: true,
            ledOff: false,
            ledRainbow: false,
            ledColor: 0x123456
        )
        let tuningArguments = SolEngineBackendOperation.setInputTuning(
            tuning,
            player: .player1
        ).arguments
        XCTAssertEqual(tuningArguments.first, "--native-set-input-tuning")
        XCTAssertEqual(value(after: "--native-player", in: tuningArguments), "Player1")
        XCTAssertEqual(value(after: "--deadzone-left", in: tuningArguments), "0.12")
        XCTAssertEqual(value(after: "--motion-sensitivity", in: tuningArguments), "125")
        XCTAssertEqual(value(after: "--led-color", in: tuningArguments), "1193046")
        XCTAssertEqual(
            SolEngineBackendOperation.testInputRumble(player: .player3).arguments,
            ["--native-test-input-rumble", "--native-player", "Player3"]
        )
        XCTAssertEqual(SolEngineBackendOperation.scanContent.arguments, ["--native-scan-content"])
        XCTAssertEqual(SolEngineBackendOperation.listProfiles.arguments, ["--native-list-profiles"])
        XCTAssertEqual(
            SolEngineBackendOperation.setProfile("profile-id").arguments,
            ["--native-set-profile", "profile-id"]
        )
        XCTAssertEqual(
            SolEngineBackendOperation.createProfile(
                name: "Player Two",
                imageBase64: "AQID"
            ).arguments,
            [
                "--native-create-profile", "Player Two",
                "--native-profile-image-base64", "AQID",
            ]
        )
        XCTAssertEqual(
            SolEngineBackendOperation.renameProfile(
                id: "profile-id",
                name: "Renamed"
            ).arguments,
            [
                "--native-rename-profile", "profile-id",
                "--native-profile-name", "Renamed",
            ]
        )
        XCTAssertEqual(
            SolEngineBackendOperation.deleteProfile(id: "profile-id").arguments,
            ["--native-delete-profile", "profile-id"]
        )
        XCTAssertEqual(
            SolEngineBackendOperation.setProfileImage(
                id: "profile-id",
                imageBase64: "AQID"
            ).arguments,
            [
                "--native-set-profile-image", "profile-id",
                "--native-profile-image-base64", "AQID",
            ]
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
