import Foundation
import XCTest
@testable import Sol

final class AppleAccountServiceTests: XCTestCase {
    func testGeneratedAvatarUsesPrivateStableAliasAndRequestedShape() throws {
        let url = try XCTUnwrap(
            AppleAccountService.avatarURL(
                userID: "private-apple-subject",
                displayName: "Zinedin Arnaut"
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "avatar.vercel.sh")
        XCTAssertTrue(components.path.hasPrefix("/zinedin-arnaut-"))
        XCTAssertFalse(url.absoluteString.contains("private-apple-subject"))
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                    guard let value = $0.value else { return nil }
                    return ($0.name, value)
                }
            ),
            ["rounded": "60", "size": "120"]
        )
    }

    func testGeneratedAvatarIsDeterministicPerAppleAccount() {
        let first = AppleAccountService.avatarURL(
            userID: "same-account",
            displayName: "Sol Player"
        )
        let second = AppleAccountService.avatarURL(
            userID: "same-account",
            displayName: "Sol Player"
        )
        let different = AppleAccountService.avatarURL(
            userID: "different-account",
            displayName: "Sol Player"
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
    }
}
