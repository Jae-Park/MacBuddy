import AppKit
import Darwin
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
    let availableGB: Double
    let pressureFreePercent: Double
    let swapGB: Double
}

struct HealthSample: Sendable {
    let timestamp: Date
    let memoryFraction: Double
    let cpuLoad: Double
    let status: HealthStatus
}

@MainActor
final class SystemMonitor: NSObject {
    private(set) var totalMemoryGB = 0.0
    private(set) var availableMemoryGB = 0.0
    private(set) var memoryPressureFreePercent = 0.0
    private(set) var swapGB = 0.0
    private(set) var cpuLoad = 0.0
    private(set) var freeDiskGB = 0.0
    private(set) var topProcesses: [ProcessSnapshot] = []
    private(set) var alertsEnabled = UserDefaults.standard.bool(forKey: "alertsEnabled")
    private(set) var history: [HealthSample] = []

    private var timer: Timer?
    private var dashboardVisible = false
    private var lastProcessCollection = Date.distantPast
    private var lastExternalFrontmostPID: Int32?

    var memoryFraction: Double {
        guard memoryPressureFreePercent > 0 else { return 0 }
        return min(max(1 - memoryPressureFreePercent / 100, 0), 1)
    }

    var status: HealthStatus {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        if (memoryPressureFreePercent < 10 && swapGB > 2) || cpuLoad > cores * 0.9 { return .strained }
        if (memoryPressureFreePercent < 25 && swapGB > 0.5) || cpuLoad > cores * 0.55 { return .busy }
        return .calm
    }

    var statusTitle: String { status.title }
    var statusColor: NSColor { status.color }
    var energyColor: NSColor { status.energyColor }
    var statusSymbol: String { status.symbol }
    var energyLevel: Double {
        let memoryHeadroom = memoryPressureFreePercent > 0 ? memoryPressureFreePercent / 100 : 1
        let cpuHeadroom = max(0, 1 - cpuLoad / (Double(ProcessInfo.processInfo.activeProcessorCount) * 0.9))
        return min(max(min(memoryHeadroom, cpuHeadroom), 0), 1)
    }
    var memorySummary: String { "\(availableMemoryGB.oneDecimal) GB 가용" }
    var memorySummaryEnglish: String { "\(availableMemoryGB.oneDecimal) GB available" }
    var memoryDetail: String { "macOS pressure \(memoryPressureFreePercent.rounded())% free · \(swapGB.oneDecimal) GB swap" }
    var cpuSummary: String { String(format: "%.2f", cpuLoad) }
    var diskSummary: String { "\(freeDiskGB.oneDecimal) GB free" }
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
            availableGB: availableMemoryGB,
            pressureFreePercent: memoryPressureFreePercent,
            swapGB: swapGB
        )
    }

    func start() {
        guard timer == nil else { return }
        if history.isEmpty { refresh() }
        let timer = Timer(timeInterval: 12, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        availableMemoryGB = memory.availableGB
        memoryPressureFreePercent = memory.pressureFreePercent
        swapGB = memory.swapGB
        cpuLoad = SystemMetrics.cpuLoad()
        freeDiskGB = SystemMetrics.freeDiskGB()

        let currentStatus = status
        history.append(HealthSample(
            timestamp: .now,
            memoryFraction: memoryFraction,
            cpuLoad: cpuLoad,
            status: currentStatus
        ))
        if history.count > 150 { history.removeFirst(history.count - 150) }

        if alertsEnabled, currentStatus == .strained, previousStatus != .strained {
            NotificationManager.sendStrainedNotification(memory: memorySummary, cpu: cpuSummary)
        }

        postUpdate()

        let processInterval: TimeInterval = currentStatus == .calm ? 30 : 12
        let elapsed = Date.now.timeIntervalSince(lastProcessCollection)
        let shouldCollect = forceProcessList ||
            (dashboardVisible && elapsed >= processInterval) ||
            (currentStatus != .calm && elapsed >= processInterval)
        guard shouldCollect else { return }

        lastProcessCollection = .now
        let protectedFrontmostPID = lastExternalFrontmostPID
        Task { [weak self] in
            let processes = await Task.detached(priority: .utility) {
                SystemMetrics.topProcesses()
            }.value
            guard let self else { return }
            self.topProcesses = self.decorate(processes, protectedFrontmostPID: protectedFrontmostPID)
            self.postUpdate()
        }
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
        guard process.id != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: process.id)
        else { return false }
        return application.terminate()
    }

    @objc private func timerFired() {
        refresh()
    }

    private func postUpdate() {
        NotificationCenter.default.post(name: .systemMonitorDidUpdate, object: self)
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
            let application = runningApplications.first { application in
                guard let bundlePath = process.bundlePath,
                      let applicationPath = application.bundleURL?.standardizedFileURL.path
                else { return application.processIdentifier == process.id }
                return applicationPath == bundlePath
            }
            guard let application else { return process }
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

    var title: String {
        switch self {
        case .calm: "All clear"
        case .busy: "Working hard"
        case .strained: "Needs attention"
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
        case .calm: NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.00, alpha: 1)
        case .busy: NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 1)
        case .strained: NSColor(calibratedRed: 0.94, green: 0.33, blue: 0.52, alpha: 1)
        }
    }

    var symbol: String {
        switch self {
        case .calm: "face.smiling"
        case .busy: "bolt.heart"
        case .strained: "exclamationmark.heart"
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

    static func sendStrainedNotification(memory: String, cpu: String) {
        let content = UNMutableNotificationContent()
        content.title = "MacBuddy: 잠깐 확인해줘"
        content.body = "메모리 \(memory), CPU load \(cpu). 메뉴바에서 무거운 앱을 확인해봐."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "strained-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private enum SystemMetrics {
    struct Memory {
        let totalGB: Double
        let availableGB: Double
        let pressureFreePercent: Double
        let swapGB: Double
    }

    static func memory() -> Memory {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return Memory(totalGB: 0, availableGB: 0, pressureFreePercent: 0, swapGB: 0)
        }
        let pageByteSize = Double(pageSize)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS, totalBytes > 0 else {
            return Memory(totalGB: 0, availableGB: 0, pressureFreePercent: 0, swapGB: 0)
        }

        let reclaimableBytes = Double(stats.free_count + stats.inactive_count + stats.speculative_count) * pageByteSize
        let fallbackPercent = min(max(reclaimableBytes / totalBytes * 100, 0), 100)
        let pressurePercent = pressureFreePercent() ?? fallbackPercent
        return Memory(
            totalGB: totalBytes.gigabytes,
            availableGB: totalBytes.gigabytes * pressurePercent / 100,
            pressureFreePercent: pressurePercent,
            swapGB: swapUsageGB()
        )
    }

    static func cpuLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
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

    private static func pressureFreePercent() -> Double? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        task.arguments = ["-Q"]
        let output = Pipe()
        task.standardOutput = output

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                  let match = text.range(of: #"System-wide memory free percentage:\s*([0-9]+)%"#, options: .regularExpression)
            else { return nil }
            let value = text[match].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            return Double(value)
        } catch {
            return nil
        }
    }
}

private extension Double {
    var gigabytes: Double { self / 1_073_741_824 }
    var oneDecimal: String { String(format: "%.1f", self) }
}
