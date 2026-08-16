import Foundation

struct VMPageCounts: Equatable, Sendable {
    let free: UInt64
    let inactive: UInt64
    let speculative: UInt64
    let purgeable: UInt64
}

struct MemoryHeadroomEstimate: Equatable, Sendable {
    let bytes: Double
    let percent: Double

    static let zero = MemoryHeadroomEstimate(bytes: 0, percent: 0)
}

enum SystemHealthPolicy {
    static let calmProcessCollectionInterval: TimeInterval = 30
    static let loadedProcessCollectionInterval: TimeInterval = 12

    static func memoryHeadroom(
        pageCounts: VMPageCounts,
        pageByteSize: Double,
        totalBytes: Double
    ) -> MemoryHeadroomEstimate {
        guard pageByteSize.isFinite, pageByteSize > 0,
              totalBytes.isFinite, totalBytes > 0
        else { return .zero }

        // HOST_VM_INFO64 free_count already includes speculative pages, while
        // purgeable pages are represented on the inactive queues. Adding those
        // counters again would inflate the estimate.
        let reclaimablePages = Double(pageCounts.free) + Double(pageCounts.inactive)
        let bytes = min(max(reclaimablePages * pageByteSize, 0), totalBytes)
        return MemoryHeadroomEstimate(
            bytes: bytes,
            percent: bytes / totalBytes * 100
        )
    }

    static func memoryLoadFraction(
        headroomPercent: Double,
        pressure: MemoryPressureState
    ) -> Double {
        let headroomLoad = min(max(1 - headroomPercent / 100, 0), 1)
        switch pressure {
        case .normal, .unknown:
            return min(headroomLoad, 0.66)
        case .warning:
            return min(max(headroomLoad, 0.75), 0.89)
        case .critical:
            return 1
        }
    }

    static func energySegments(for loadFraction: Double) -> Int {
        max(1, min(6, Int((min(max(loadFraction, 0), 1) * 6).rounded())))
    }

    static func processCollectionInterval(for status: HealthStatus) -> TimeInterval {
        status == .calm ? calmProcessCollectionInterval : loadedProcessCollectionInterval
    }

    static func shouldCollectProcesses(
        force: Bool,
        dashboardVisible: Bool,
        status: HealthStatus,
        elapsed: TimeInterval
    ) -> Bool {
        if force { return true }
        let interval = processCollectionInterval(for: status)
        guard elapsed >= interval else { return false }
        return dashboardVisible || status != .calm
    }
}

struct CPUStatusTracker: Sendable {
    private(set) var status = HealthStatus.calm
    private var pendingStatus: HealthStatus?
    private var pendingSamples = 0

    mutating func update(usagePercent: Double) {
        let usage = min(max(usagePercent, 0), 100)
        let target: HealthStatus
        switch status {
        case .calm:
            target = usage >= 90 ? .strained : (usage >= 75 ? .busy : .calm)
        case .busy:
            target = usage >= 90 ? .strained : (usage < 65 ? .calm : .busy)
        case .strained:
            target = usage < 65 ? .calm : (usage < 80 ? .busy : .strained)
        }

        guard target != status else {
            pendingStatus = nil
            pendingSamples = 0
            return
        }

        if pendingStatus == target {
            pendingSamples += 1
        } else {
            pendingStatus = target
            pendingSamples = 1
        }

        let requiredSamples = target.severity > status.severity
            ? (target == .strained ? 5 : 3)
            : 5
        guard pendingSamples >= requiredSamples else { return }
        status = target
        pendingStatus = nil
        pendingSamples = 0
    }

    mutating func reset() {
        self = CPUStatusTracker()
    }
}
