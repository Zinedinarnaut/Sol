import XCTest
@testable import SolDLSM

final class DLSMGPUTimingAccumulatorTests: XCTestCase {
    func testReportsBoundedAverageAndP95AtConfiguredInterval() throws {
        let accumulator = DLSMGPUTimingAccumulator(
            reportInterval: 5,
            windowCapacity: 4
        )

        XCTAssertNil(accumulator.record(milliseconds: 1))
        XCTAssertNil(accumulator.record(milliseconds: 2))
        XCTAssertNil(accumulator.record(milliseconds: 3))
        XCTAssertNil(accumulator.record(milliseconds: 4))
        let report = try XCTUnwrap(
            accumulator.record(milliseconds: 20)
        )

        XCTAssertEqual(report.sampleCount, 5)
        XCTAssertEqual(report.averageMilliseconds, 6, accuracy: 0.0001)
        XCTAssertEqual(report.p95Milliseconds, 20, accuracy: 0.0001)
    }

    func testRejectsInvalidSamplesAndResetClearsHistory() {
        let accumulator = DLSMGPUTimingAccumulator(
            reportInterval: 1,
            windowCapacity: 4
        )

        XCTAssertNil(accumulator.record(milliseconds: 0))
        XCTAssertNil(accumulator.record(milliseconds: .infinity))
        XCTAssertEqual(
            accumulator.record(milliseconds: 2)?.sampleCount,
            1
        )

        accumulator.reset()
        XCTAssertNil(accumulator.snapshot)
    }
}
