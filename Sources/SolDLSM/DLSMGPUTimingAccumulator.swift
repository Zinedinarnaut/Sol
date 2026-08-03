import Foundation

struct DLSMGPUTimingSnapshot: Equatable, Sendable {
    let sampleCount: UInt64
    let averageMilliseconds: Double
    let p95Milliseconds: Double
}

/// Thread-safe bounded timing statistics for Metal completion callbacks.
final class DLSMGPUTimingAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let reportInterval: UInt64
    private let windowCapacity: Int
    private var sampleCount: UInt64 = 0
    private var totalMilliseconds = 0.0
    private var recentMilliseconds: [Double] = []

    init(reportInterval: UInt64 = 300, windowCapacity: Int = 600) {
        self.reportInterval = max(1, reportInterval)
        self.windowCapacity = max(1, windowCapacity)
        recentMilliseconds.reserveCapacity(self.windowCapacity)
    }

    func record(milliseconds: Double) -> DLSMGPUTimingSnapshot? {
        guard milliseconds.isFinite, milliseconds > 0 else {
            return nil
        }
        return lock.withLock {
            sampleCount += 1
            totalMilliseconds += milliseconds
            recentMilliseconds.append(milliseconds)
            if recentMilliseconds.count > windowCapacity {
                recentMilliseconds.removeFirst(
                    recentMilliseconds.count - windowCapacity
                )
            }
            guard sampleCount % reportInterval == 0 else {
                return nil
            }
            return snapshotLocked()
        }
    }

    var snapshot: DLSMGPUTimingSnapshot? {
        lock.withLock {
            guard sampleCount > 0 else {
                return nil
            }
            return snapshotLocked()
        }
    }

    func reset() {
        lock.withLock {
            sampleCount = 0
            totalMilliseconds = 0
            recentMilliseconds.removeAll(keepingCapacity: true)
        }
    }

    private func snapshotLocked() -> DLSMGPUTimingSnapshot {
        let sorted = recentMilliseconds.sorted()
        let percentileIndex = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return DLSMGPUTimingSnapshot(
            sampleCount: sampleCount,
            averageMilliseconds:
                totalMilliseconds / Double(sampleCount),
            p95Milliseconds: sorted[percentileIndex]
        )
    }
}
