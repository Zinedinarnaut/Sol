import AppKit
import XCTest
@testable import Sol

final class SolPixelAvatarTests: XCTestCase {
    func testStableDefaultIsDeterministicForProfileIdentity() {
        let profileID = UUID(uuidString: "E19B55F9-5101-43A8-A7F7-A8E3E3C78561")!

        XCTAssertEqual(
            SolPixelAvatar.stableDefault(profileID: profileID),
            SolPixelAvatar.stableDefault(profileID: profileID)
        )
    }

    func testCandidateBatchIsDeterministicUniqueAndUsesRequestedPalette() {
        let first = SolPixelAvatar.candidates(
            style: .aurora,
            baseSeed: 42
        )
        let second = SolPixelAvatar.candidates(
            style: .aurora,
            baseSeed: 42
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 12)
        XCTAssertEqual(Set(first).count, 12)
        XCTAssertTrue(first.allSatisfy { $0.style == .aurora })
    }

    @MainActor
    func testRendererProducesStablePixelPNG() throws {
        let avatar = SolPixelAvatar(seed: 8_675_309, style: .solar)
        let first = try XCTUnwrap(
            SolPixelAvatarRenderer.shared.pngData(for: avatar)
        )
        let second = try XCTUnwrap(
            SolPixelAvatarRenderer.shared.pngData(for: avatar)
        )

        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.count, 1_000)
    }
}
