import CoreGraphics
import XCTest
@testable import Sol

final class SolEngineSurfaceSizingTests: XCTestCase {
    func testCapsTransientSwiftUILayoutAgainstTheRealScreen() {
        let logicalSize = SolEngineSurfaceSizing.logicalSize(
            bounds: CGSize(width: 1_512, height: 50_068),
            window: CGSize(width: 1_512, height: 50_068),
            screen: CGSize(width: 1_512, height: 949)
        )

        XCTAssertEqual(logicalSize, CGSize(width: 1_512, height: 949))
        XCTAssertEqual(
            logicalSize.map { SolEngineSurfaceSizing.pixelSize(logical: $0, scale: 2) },
            CGSize(width: 3_024, height: 1_898)
        )
    }

    func testIgnoresTransientZeroSizedWindowCandidate() {
        XCTAssertEqual(
            SolEngineSurfaceSizing.logicalSize(
                bounds: CGSize(width: 1_280, height: 720),
                window: .zero,
                screen: CGSize(width: 1_512, height: 949)
            ),
            CGSize(width: 1_280, height: 720)
        )
    }

    func testRejectsSurfaceBeforeItIsLargeEnoughToLaunch() {
        XCTAssertNil(
            SolEngineSurfaceSizing.logicalSize(
                bounds: CGSize(width: 1, height: 1),
                window: CGSize(width: 1_512, height: 949),
                screen: CGSize(width: 1_512, height: 949)
            )
        )
        XCTAssertNil(
            SolEngineSurfaceSizing.validatedPixelSize(
                CGSize(width: 3_024, height: CGFloat.infinity)
            )
        )
    }

    func testCapsHugePixelSurfacesWithoutChangingAspectRatio() throws {
        let original = CGSize(width: 15_360, height: 8_640)
        let result = try XCTUnwrap(SolEngineSurfaceSizing.validatedPixelSize(original))

        XCTAssertLessThanOrEqual(result.width, SolEngineSurfaceSizing.maximumPixelDimension)
        XCTAssertLessThanOrEqual(result.height, SolEngineSurfaceSizing.maximumPixelDimension)
        XCTAssertLessThanOrEqual(
            result.width * result.height,
            SolEngineSurfaceSizing.maximumPixelCount
        )
        XCTAssertEqual(result.width / result.height, original.width / original.height, accuracy: 0.001)
    }
}
