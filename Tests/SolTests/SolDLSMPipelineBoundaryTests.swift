import QuartzCore
import XCTest
@testable import SolDLSM

final class SolDLSMPipelineBoundaryTests: XCTestCase {
    private typealias PresentCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?
    ) -> Int32

    func testLibraryOwnsFrameCallbackAndRejectsMissingFrame() {
        let pipeline = SolDLSMPipeline(outputLayer: CAMetalLayer())
        let callback = unsafeBitCast(
            pipeline.callbackPointer,
            to: PresentCallback.self
        )

        XCTAssertNotEqual(UInt(bitPattern: pipeline.callbackContext), 0)
        XCTAssertEqual(callback(pipeline.callbackContext, nil), 0)
    }
}
