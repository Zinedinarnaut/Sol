import Foundation
import XCTest
@testable import Sol

final class GitHubUpdateServiceTests: XCTestCase {
    func testSemanticVersionOrdersPrereleasesAndNumericIdentifiers() throws {
        let beta2 = try XCTUnwrap(SolSemanticVersion("v0.2.0-beta.2"))
        let beta10 = try XCTUnwrap(SolSemanticVersion("0.2.0-beta.10"))
        let stable = try XCTUnwrap(SolSemanticVersion("0.2.0"))

        XCTAssertLessThan(beta2, beta10)
        XCTAssertLessThan(beta10, stable)
        XCTAssertEqual(stable, SolSemanticVersion("v0.2.0+build.7"))
    }

    @MainActor
    func testSelectsNewestReleaseWithDiskImageAndChecksum() throws {
        let current = try XCTUnwrap(SolSemanticVersion("0.1.1"))
        let incomplete = release(version: "0.3.0", assetNames: ["Sol-0.3.0-macOS.dmg"])
        let beta = release(
            version: "0.2.0-beta.1",
            assetNames: ["Sol-0.2.0-beta.1-macOS.dmg", "Sol-0.2.0-beta.1-macOS.dmg.sha256"]
        )
        let stable = release(
            version: "0.2.0",
            assetNames: ["Sol-0.2.0-macOS.dmg", "Sol-0.2.0-macOS.dmg.sha256"]
        )

        XCTAssertEqual(
            GitHubUpdateService.newestDownloadableRelease(
                in: [incomplete, beta, stable],
                newerThan: current
            )?.tagName,
            "v0.2.0"
        )
    }

    @MainActor
    func testChecksumParserAcceptsSidecarFormats() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            GitHubUpdateService.parseChecksum(Data("\(digest)  Sol.dmg\n".utf8)),
            digest
        )
        XCTAssertNil(GitHubUpdateService.parseChecksum(Data("not-a-checksum".utf8)))
    }

    private func release(version: String, assetNames: [String]) -> SolRelease {
        SolRelease(
            tagName: "v\(version)",
            name: "Sol \(version)",
            htmlURL: URL(string: "https://github.com/Zinedinarnaut/Sol/releases/tag/v\(version)")!,
            draft: false,
            prerelease: version.contains("-"),
            assets: assetNames.map { name in
                SolReleaseAsset(
                    name: name,
                    browserDownloadURL: URL(string: "https://github.com/Zinedinarnaut/Sol/releases/download/v\(version)/\(name)")!,
                    size: 100
                )
            }
        )
    }
}
