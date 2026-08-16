import XCTest
@testable import MacBuddy

final class SystemHealthPolicyTests: XCTestCase {
    func testHeadroomDoesNotDoubleCountSpeculativeOrPurgeablePages() {
        let baseline = SystemHealthPolicy.memoryHeadroom(
            pageCounts: VMPageCounts(free: 100, inactive: 200, speculative: 0, purgeable: 0),
            pageByteSize: 4_096,
            totalBytes: 4_096_000
        )
        let duplicatedCounters = SystemHealthPolicy.memoryHeadroom(
            pageCounts: VMPageCounts(free: 100, inactive: 200, speculative: 900, purgeable: 700),
            pageByteSize: 4_096,
            totalBytes: 4_096_000
        )

        XCTAssertEqual(baseline, duplicatedCounters)
        XCTAssertEqual(baseline.bytes, 1_228_800, accuracy: 0.001)
        XCTAssertEqual(baseline.percent, 30, accuracy: 0.001)
    }

    func testHeadroomClampsToPhysicalMemoryAndRejectsInvalidInputs() {
        let clamped = SystemHealthPolicy.memoryHeadroom(
            pageCounts: VMPageCounts(free: 800, inactive: 800, speculative: 0, purgeable: 0),
            pageByteSize: 4_096,
            totalBytes: 4_096_000
        )

        XCTAssertEqual(clamped.bytes, 4_096_000, accuracy: 0.001)
        XCTAssertEqual(clamped.percent, 100, accuracy: 0.001)
        XCTAssertEqual(
            SystemHealthPolicy.memoryHeadroom(
                pageCounts: VMPageCounts(free: 1, inactive: 1, speculative: 0, purgeable: 0),
                pageByteSize: 0,
                totalBytes: 4_096
            ),
            .zero
        )
    }

    func testMemoryPressureBandsMapToExpectedSixSegmentLevels() {
        let calmMaximum = SystemHealthPolicy.memoryLoadFraction(headroomPercent: 0, pressure: .normal)
        let warningMinimum = SystemHealthPolicy.memoryLoadFraction(headroomPercent: 100, pressure: .warning)
        let warningMaximum = SystemHealthPolicy.memoryLoadFraction(headroomPercent: 0, pressure: .warning)
        let critical = SystemHealthPolicy.memoryLoadFraction(headroomPercent: 100, pressure: .critical)

        XCTAssertEqual(SystemHealthPolicy.energySegments(for: 0), 1)
        XCTAssertEqual(SystemHealthPolicy.energySegments(for: calmMaximum), 4)
        XCTAssertEqual(SystemHealthPolicy.energySegments(for: warningMinimum), 5)
        XCTAssertEqual(SystemHealthPolicy.energySegments(for: warningMaximum), 5)
        XCTAssertEqual(SystemHealthPolicy.energySegments(for: critical), 6)
    }

    func testCPUStatusRequiresSustainedSamplesAndUsesHysteresis() {
        var tracker = CPUStatusTracker()

        for _ in 0..<2 { tracker.update(usagePercent: 80) }
        XCTAssertEqual(tracker.status, .calm)
        tracker.update(usagePercent: 80)
        XCTAssertEqual(tracker.status, .busy)

        for _ in 0..<4 { tracker.update(usagePercent: 95) }
        XCTAssertEqual(tracker.status, .busy)
        tracker.update(usagePercent: 95)
        XCTAssertEqual(tracker.status, .strained)

        for _ in 0..<4 { tracker.update(usagePercent: 75) }
        XCTAssertEqual(tracker.status, .strained)
        tracker.update(usagePercent: 75)
        XCTAssertEqual(tracker.status, .busy)

        for _ in 0..<4 { tracker.update(usagePercent: 60) }
        XCTAssertEqual(tracker.status, .busy)
        tracker.update(usagePercent: 60)
        XCTAssertEqual(tracker.status, .calm)
    }

    func testProcessCollectionPolicyThrottlesCalmAndLoadedRefreshes() {
        XCTAssertTrue(SystemHealthPolicy.shouldCollectProcesses(
            force: true,
            dashboardVisible: false,
            status: .calm,
            elapsed: 0
        ))
        XCTAssertFalse(SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: false,
            status: .calm,
            elapsed: 300
        ))
        XCTAssertFalse(SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: true,
            status: .calm,
            elapsed: 29.9
        ))
        XCTAssertTrue(SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: true,
            status: .calm,
            elapsed: 30
        ))
        XCTAssertFalse(SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: false,
            status: .busy,
            elapsed: 11.9
        ))
        XCTAssertTrue(SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: false,
            status: .busy,
            elapsed: 12
        ))
    }
}
