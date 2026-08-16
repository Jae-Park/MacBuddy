import AppKit
import Darwin
import Dispatch
import Foundation
import MachO
import UserNotifications

extension Notification.Name {
    static let systemMonitorDidUpdate = Notification.Name("MacBuddy.systemMonitorDidUpdate")
}

struct ProcessSnapshot: Sendable {
    let id: Int32
    let name: String
    let cpu: Double
    let memoryMB: Double
    let bundlePath: String?
    let bundleIdentifier: String?
    let isRegularApplication: Bool
    let isProtected: Bool
}

struct MemoryHealthSnapshot: Sendable {
    let headroomGB: Double
    let headroomPercent: Double
    let pressure: MemoryPressureState
    let swapGB: Double
}

struct HealthSample: Sendable {
    let timestamp: Date
    let memoryFraction: Double
    let cpuUsageFraction: Double
    let status: HealthStatus
}

enum SystemLoadCause: Sendable {
    case memory, cpu, both
}

enum MemoryPressureState: Equatable, Sendable {
    case normal, warning, critical, unknown

    var healthStatus: HealthStatus {
        switch self {
        case .normal, .unknown: .calm
        case .warning: .busy
        case .critical: .strained
        }
    }

    var title: String {
        switch self {
        case .normal: tr("normal", "정상")
        case .warning: tr("warning", "경고")
        case .critical: tr("critical", "위험")
        case .unknown: tr("unknown", "확인 중")
        }
    }
}

@MainActor
final class SystemMonitor: NSObject {
    private(set) var totalMemoryGB = 0.0
    private(set) var memoryHeadroomGB = 0.0
    private(set) var memoryHeadroomPercent = 0.0
    private(set) var memoryPressureState = MemoryPressureState.unknown
    private(set) var swapGB = 0.0
    private(set) var cpuUsagePercent = 0.0
    private(set) var freeDiskGB = 0.0
    private(set) var topProcesses: [ProcessSnapshot] = []
    private(set) var alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled")
    private(set) var history: [HealthSample] = []

    private var memoryTimer: Timer?
    private var cpuTimer: Timer?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var previousCPUTicks: SystemMetrics.CPUTicks?
    private var cpuStatusTracker = CPUStatusTracker()
    private var dashboardVisible = false
    private var lastProcessCollection = Date.distantPast
    private var lastExternalFrontmostPID: Int32?
    private var processCollectionInFlight = false
    private var processCollectionPending = false
    private var lastStrainedNotification = Date.distantPast

    private var cpuStatus: HealthStatus { cpuStatusTracker.status }

    var memoryFraction: Double {
        guard totalMemoryGB > 0 else { return 0 }
        return SystemHealthPolicy.memoryLoadFraction(
            headroomPercent: memoryHeadroomPercent,
            pressure: memoryPressureState
        )
    }

    var cpuUsageFraction: Double {
        min(max(cpuUsagePercent / 100, 0), 1)
    }

    var status: HealthStatus {
        HealthStatus.maximum(memoryPressureState.healthStatus, cpuStatus)
    }

    var dominantLoadCause: SystemLoadCause {
        let difference = memoryFraction - cpuUsageFraction
        if abs(difference) <= 0.10 { return .both }
        return difference > 0 ? .memory : .cpu
    }

    var statusTitle: String { status.title }
    var statusColor: NSColor { status.color }
    var energyColor: NSColor { status.energyColor }
    var statusSymbol: String { status.symbol }
    var energyLevel: Double {
        max(memoryFraction, cpuUsageFraction)
    }
    var memorySummary: String {
        tr("\(memoryHeadroomGB.oneDecimal) GB headroom est.", "\(memoryHeadroomGB.oneDecimal) GB 여유 추정")
    }
    var memoryDetail: String {
        tr(
            "Pressure \(memoryPressureState.title) · headroom est. \(Int(memoryHeadroomPercent.rounded()))% · \(swapGB.oneDecimal) GB swap",
            "압력 \(memoryPressureState.title) · 여유 추정 \(Int(memoryHeadroomPercent.rounded()))% · swap \(swapGB.oneDecimal) GB"
        )
    }
    var cpuSummary: String { String(format: "%.0f%%", cpuUsagePercent) }
    var diskSummary: String { tr("\(freeDiskGB.oneDecimal) GB free", "\(freeDiskGB.oneDecimal) GB 여유") }
    var optimizationCandidates: [ProcessSnapshot] {
        var seen = Set<String>()
        return topProcesses.filter { process in
            guard process.isRegularApplication, !process.isProtected else { return false }
            let key = process.bundleIdentifier ?? "pid:\(process.id)"
            return seen.insert(key).inserted
        }
    }

    var memoryHealthSnapshot: MemoryHealthSnapshot {
        MemoryHealthSnapshot(
            headroomGB: memoryHeadroomGB,
            headroomPercent: memoryHeadroomPercent,
            pressure: memoryPressureState,
            swapGB: swapGB
        )
    }

    func start() {
        guard memoryTimer == nil, cpuTimer == nil else { return }
        installWorkspaceObservers()
        startMemoryPressureMonitoring()
        previousCPUTicks = SystemMetrics.cpuTicks()
        if history.isEmpty { refresh() }

        let memoryTimer = Timer(timeInterval: 12, target: self, selector: #selector(memoryTimerFired), userInfo: nil, repeats: true)
        memoryTimer.tolerance = 1.2
        RunLoop.main.add(memoryTimer, forMode: .common)
        self.memoryTimer = memoryTimer

        let cpuTimer = Timer(timeInterval: 2, target: self, selector: #selector(cpuTimerFired), userInfo: nil, repeats: true)
        cpuTimer.tolerance = 0.2
        RunLoop.main.add(cpuTimer, forMode: .common)
        self.cpuTimer = cpuTimer
    }

    func dashboardOpened() {
        dashboardVisible = true
        refresh(forceProcessList: true)
    }

    func dashboardClosed() {
        dashboardVisible = false
    }

    func refresh(forceProcessList: Bool = false) {
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPID != ownPID {
            lastExternalFrontmostPID = frontmostPID
        }

        let previousStatus = status
        let memory = SystemMetrics.memory()
        totalMemoryGB = memory.totalGB
        memoryHeadroomGB = memory.headroomGB
        memoryHeadroomPercent = memory.headroomPercent
        memoryPressureState = memory.pressure
        swapGB = memory.swapGB
        freeDiskGB = SystemMetrics.freeDiskGB()

        let currentStatus = status
        publishUpdate(previousStatus: previousStatus, recordSample: history.isEmpty)

        let elapsed = Date.now.timeIntervalSince(lastProcessCollection)
        let shouldCollect = SystemHealthPolicy.shouldCollectProcesses(
            force: forceProcessList,
            dashboardVisible: dashboardVisible,
            status: currentStatus,
            elapsed: elapsed
        )
        guard shouldCollect else { return }

        requestProcessCollection(protectedFrontmostPID: lastExternalFrontmostPID)
    }

    func setAlertsEnabled(_ enabled: Bool) {
        guard enabled else {
            alertsEnabled = false
            UserDefaults.standard.set(false, forKey: "alertsEnabled")
            postUpdate()
            return
        }

        Task { [weak self] in
            let granted = await NotificationManager.requestAuthorization()
            guard let self, granted else { return }
            self.alertsEnabled = true
            UserDefaults.standard.set(true, forKey: "alertsEnabled")
            self.postUpdate()
        }
    }

    @discardableResult
    func quit(_ process: ProcessSnapshot) -> Bool {
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        guard !process.isProtected,
              process.isRegularApplication,
              process.id != ownPID,
              let expectedBundlePath = process.bundlePath,
              let expectedBundleIdentifier = process.bundleIdentifier,
              let application = NSRunningApplication(processIdentifier: process.id),
              !application.isTerminated,
              application.activationPolicy == .regular,
              application.bundleIdentifier == expectedBundleIdentifier,
              application.bundleURL?.standardizedFileURL.path == expectedBundlePath
        else { return false }
        return application.terminate()
    }

    @objc private func memoryTimerFired() {
        refresh()
    }

    @objc private func cpuTimerFired() {
        guard let currentTicks = SystemMetrics.cpuTicks() else { return }
        defer { previousCPUTicks = currentTicks }
        guard let previousCPUTicks else { return }

        let previousStatus = status
        let currentUsage = SystemMetrics.cpuUsagePercent(from: previousCPUTicks, to: currentTicks)
        cpuUsagePercent = cpuUsagePercent > 0
            ? cpuUsagePercent * 0.35 + currentUsage * 0.65
            : currentUsage
        cpuStatusTracker.update(usagePercent: cpuUsagePercent)
        publishUpdate(previousStatus: previousStatus, recordSample: true)
    }

    @objc private func systemWillSleep() {
        previousCPUTicks = nil
    }

    @objc private func systemDidWake() {
        previousCPUTicks = SystemMetrics.cpuTicks()
        cpuUsagePercent = 0
        cpuStatusTracker.reset()
        refresh(forceProcessList: dashboardVisible)
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self, let event = self.memoryPressureSource?.data else { return }
            self.memoryPressureEventFired(event)
        }
        source.activate()
    }

    private func memoryPressureEventFired(_ event: DispatchSource.MemoryPressureEvent) {
        let previousStatus = status
        if event.contains(.critical) {
            memoryPressureState = .critical
        } else if event.contains(.warning) {
            memoryPressureState = .warning
        } else if event.contains(.normal) {
            memoryPressureState = .normal
        } else {
            memoryPressureState = SystemMetrics.memoryPressureState()
        }
        publishUpdate(previousStatus: previousStatus, recordSample: true)

        if memoryPressureState != .normal {
            requestProcessCollectionIfDue(protectedFrontmostPID: lastExternalFrontmostPID)
        }
    }

    private func publishUpdate(previousStatus: HealthStatus, recordSample: Bool) {
        let currentStatus = status
        if recordSample {
            history.append(HealthSample(
                timestamp: .now,
                memoryFraction: memoryFraction,
                cpuUsageFraction: cpuUsageFraction,
                status: currentStatus
            ))
            if history.count > 450 { history.removeFirst(history.count - 450) }
        }

        let now = Date.now
        if alertsEnabled,
           currentStatus == .strained,
           previousStatus != .strained,
           now.timeIntervalSince(lastStrainedNotification) >= 15 * 60 {
            lastStrainedNotification = now
            NotificationManager.sendStrainedNotification(
                memory: memorySummary,
                cpu: cpuSummary,
                cause: dominantLoadCause
            )
        }
        postUpdate()
    }

    private func postUpdate() {
        NotificationCenter.default.post(name: .systemMonitorDidUpdate, object: self)
    }

    private func requestProcessCollection(protectedFrontmostPID: Int32?) {
        guard !processCollectionInFlight else {
            processCollectionPending = true
            return
        }

        processCollectionInFlight = true
        lastProcessCollection = .now
        Task { [weak self] in
            let processes = await Task.detached(priority: .utility) {
                SystemMetrics.topProcesses()
            }.value
            guard let self else { return }
            self.processCollectionInFlight = false
            self.topProcesses = self.decorate(processes, protectedFrontmostPID: protectedFrontmostPID)
            self.postUpdate()

            if self.processCollectionPending {
                self.processCollectionPending = false
                self.requestProcessCollectionIfDue(protectedFrontmostPID: self.lastExternalFrontmostPID)
            }
        }
    }

    private func requestProcessCollectionIfDue(protectedFrontmostPID: Int32?) {
        let elapsed = Date.now.timeIntervalSince(lastProcessCollection)
        guard SystemHealthPolicy.shouldCollectProcesses(
            force: false,
            dashboardVisible: false,
            status: status,
            elapsed: elapsed
        ) else { return }
        requestProcessCollection(protectedFrontmostPID: protectedFrontmostPID)
    }

    private func decorate(
        _ processes: [ProcessSnapshot],
        protectedFrontmostPID: Int32?
    ) -> [ProcessSnapshot] {
        let runningApplications = NSWorkspace.shared.runningApplications
        let protectedBundleIdentifiers: Set<String> = [
            Bundle.main.bundleIdentifier ?? "com.jaeyong.macbuddy",
            "com.apple.finder",
            "com.apple.dock",
            "com.apple.loginwindow"
        ]

        return processes.map { process in
            guard let bundlePath = process.bundlePath else { return process }
            let applications = runningApplications.filter { application in
                application.bundleURL?.standardizedFileURL.path == bundlePath
            }
            guard applications.count == 1, let application = applications.first else {
                return ProcessSnapshot(
                    id: process.id,
                    name: process.name,
                    cpu: process.cpu,
                    memoryMB: process.memoryMB,
                    bundlePath: process.bundlePath,
                    bundleIdentifier: applications.first?.bundleIdentifier,
                    isRegularApplication: false,
                    isProtected: true
                )
            }
            let bundleIdentifier = application.bundleIdentifier
            let applicationPID = application.processIdentifier
            let protected = applicationPID == protectedFrontmostPID ||
                applicationPID == ProcessInfo.processInfo.processIdentifier ||
                bundleIdentifier.map(protectedBundleIdentifiers.contains) == true
            return ProcessSnapshot(
                id: applicationPID,
                name: application.localizedName ?? process.name,
                cpu: process.cpu,
                memoryMB: process.memoryMB,
                bundlePath: process.bundlePath,
                bundleIdentifier: bundleIdentifier,
                isRegularApplication: application.activationPolicy == .regular,
                isProtected: protected
            )
        }
    }
}

enum HealthStatus: Equatable, Sendable {
    case calm, busy, strained

    var severity: Int {
        switch self {
        case .calm: 0
        case .busy: 1
        case .strained: 2
        }
    }

    static func maximum(_ lhs: HealthStatus, _ rhs: HealthStatus) -> HealthStatus {
        lhs.severity >= rhs.severity ? lhs : rhs
    }

    var title: String {
        switch self {
        case .calm: tr("All clear", "상태 좋아")
        case .busy: tr("Working hard", "조금 바빠")
        case .strained: tr("Needs attention", "확인이 필요해")
        }
    }

    var color: NSColor {
        switch self {
        case .calm: .systemMint
        case .busy: .systemOrange
        case .strained: .systemPink
        }
    }

    var energyColor: NSColor {
        switch self {
        case .calm: NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.52, alpha: 1)
        case .busy: NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 1)
        case .strained: NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.25, alpha: 1)
        }
    }

    var symbol: String {
        switch self {
        case .calm: "face.smiling"
        case .busy: "bolt.heart"
        case .strained: "exclamationmark.triangle.fill"
        }
    }
}

private enum NotificationManager {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func sendStrainedNotification(memory: String, cpu: String, cause: SystemLoadCause) {
        let content = UNMutableNotificationContent()
        content.title = tr("MacBuddy needs a quick check", "MacBuddy: 잠깐 확인해줘")
        switch cause {
        case .memory:
            content.body = tr("Memory pressure is high (\(memory)). Check heavy apps from the menu bar.", "메모리 압력이 높아 (\(memory)). 메뉴바에서 무거운 앱을 확인해봐.")
        case .cpu:
            content.body = tr("CPU usage is high (\(cpu)). Check active apps from the menu bar.", "CPU 사용률이 높아 (\(cpu)). 메뉴바에서 실행 중인 앱을 확인해봐.")
        case .both:
            content.body = tr("CPU usage is \(cpu), with \(memory). Check the menu bar.", "CPU 사용률 \(cpu), 메모리 \(memory). 메뉴바에서 확인해봐.")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "MacBuddy.strained", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private enum SystemMetrics {
    struct Memory {
        let totalGB: Double
        let headroomGB: Double
        let headroomPercent: Double
        let pressure: MemoryPressureState
        let swapGB: Double
    }

    struct CPUTicks {
        let user: UInt32
        let system: UInt32
        let idle: UInt32
        let nice: UInt32
    }

    static func memory() -> Memory {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            return Memory(totalGB: 0, headroomGB: 0, headroomPercent: 0, pressure: .unknown, swapGB: 0)
        }
        let pageByteSize = Double(pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }

        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, totalBytes > 0 else {
            return Memory(totalGB: 0, headroomGB: 0, headroomPercent: 0, pressure: .unknown, swapGB: 0)
        }

        let headroom = SystemHealthPolicy.memoryHeadroom(
            pageCounts: VMPageCounts(
                free: UInt64(stats.free_count),
                inactive: UInt64(stats.inactive_count),
                speculative: UInt64(stats.speculative_count),
                purgeable: UInt64(stats.purgeable_count)
            ),
            pageByteSize: pageByteSize,
            totalBytes: totalBytes
        )
        return Memory(
            totalGB: totalBytes.gigabytes,
            headroomGB: headroom.bytes.gigabytes,
            headroomPercent: headroom.percent,
            pressure: memoryPressureState(),
            swapGB: swapUsageGB()
        )
    }

    static func memoryPressureState() -> MemoryPressureState {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    static func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    static func cpuUsagePercent(from previous: CPUTicks, to current: CPUTicks) -> Double {
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let idle = UInt64(current.idle &- previous.idle)
        let nice = UInt64(current.nice &- previous.nice)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(max(Double(busy) / Double(total) * 100, 0), 100)
    }

    static func freeDiskGB() -> Double {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(values?.volumeAvailableCapacityForImportantUsage ?? 0).gigabytes
    }

    static func topProcesses() -> [ProcessSnapshot] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        let output = Pipe()
        task.standardOutput = output

        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else { return [] }

            struct Aggregate {
                var id: Int32
                var name: String
                var cpu: Double
                var rssKB: Double
                var bundlePath: String
            }

            let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
            var aggregates: [String: Aggregate] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                guard fields.count == 4,
                      let pid = Int32(fields[0]),
                      let cpu = Double(fields[1]),
                      let rssKB = Double(fields[2]),
                      pid != currentPID,
                      let bundlePath = outermostApplicationPath(in: String(fields[3]))
                else { continue }

                if var aggregate = aggregates[bundlePath] {
                    aggregate.cpu += cpu
                    aggregate.rssKB += rssKB
                    aggregates[bundlePath] = aggregate
                } else {
                    let name = URL(fileURLWithPath: bundlePath)
                        .deletingPathExtension()
                        .lastPathComponent
                    aggregates[bundlePath] = Aggregate(
                        id: pid,
                        name: name,
                        cpu: cpu,
                        rssKB: rssKB,
                        bundlePath: bundlePath
                    )
                }
            }

            return aggregates.values
                .filter { $0.rssKB >= 50 * 1024 }
                .map { aggregate in
                    ProcessSnapshot(
                        id: aggregate.id,
                        name: aggregate.name,
                        cpu: aggregate.cpu,
                        memoryMB: aggregate.rssKB / 1024,
                        bundlePath: aggregate.bundlePath,
                        bundleIdentifier: nil,
                        isRegularApplication: false,
                        isProtected: false
                    )
                }
                .sorted { $0.memoryMB > $1.memoryMB }
                .prefix(20)
                .map { $0 }
        } catch {
            return []
        }
    }

    private static func outermostApplicationPath(in command: String) -> String? {
        guard let appBoundary = command.range(of: ".app/", options: [.caseInsensitive]) else { return nil }
        return String(command[..<appBoundary.lowerBound]) + ".app"
    }

    private static func swapUsageGB() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? Double(usage.xsu_used).gigabytes : 0
    }

}

private extension Double {
    var gigabytes: Double { self / 1_073_741_824 }
    var oneDecimal: String { String(format: "%.1f", self) }
}
