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
        XCTAssertEqual(SolEngineBackendOperation.scanContent.arguments, ["--native-scan-content"])
        XCTAssertEqual(SolEngineBackendOperation.listProfiles.arguments, ["--native-list-profiles"])
        XCTAssertEqual(
            SolEngineBackendOperation.setProfile("profile-id").arguments,
            ["--native-set-profile", "profile-id"]
        )
    }
}
