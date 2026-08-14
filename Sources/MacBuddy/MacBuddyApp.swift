import AppKit
import ServiceManagement

@main
enum MacBuddyMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SystemMonitor()
    private var mascot: MascotWindowController?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let mascot = MascotWindowController(monitor: monitor)
        self.mascot = mascot
        statusBar = StatusBarController(monitor: monitor, mascot: mascot)
        monitor.start()
        mascot.show()
        LoginItemManager.enable()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mascot?.show()
        return true
    }
}

private enum LoginItemManager {
    static func enable() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("MacBuddy could not register as a login item: \(error.localizedDescription)")
        }
    }
}

@MainActor
private final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor: SystemMonitor
    private let mascot: MascotWindowController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let dashboard: DashboardViewController

    init(monitor: SystemMonitor, mascot: MascotWindowController) {
        self.monitor = monitor
        self.mascot = mascot
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dashboard = DashboardViewController(monitor: monitor, mascot: mascot)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "MacBuddy"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = dashboard
        popover.delegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(monitorDidUpdate),
            name: .systemMonitorDidUpdate,
            object: monitor
        )
        updateStatusIcon()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            dashboard.update()
            monitor.dashboardOpened()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func monitorDidUpdate() {
        updateStatusIcon()
        if popover.isShown { dashboard.update() }
    }

    func popoverWillClose(_ notification: Notification) {
        monitor.dashboardClosed()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: monitor.statusSymbol, accessibilityDescription: monitor.statusTitle)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel("MacBuddy, \(monitor.statusTitle)")
    }
}

@MainActor
private final class DashboardViewController: NSViewController {
    private let monitor: SystemMonitor
    private let mascot: MascotWindowController

    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let memoryRow = MetricRowView(title: "Memory")
    private let cpuRow = MetricRowView(title: "CPU load")
    private let diskRow = MetricRowView(title: "Disk")
    private let processStack = NSStackView()
    private let chart = HealthHistoryChartView()
    private let floatingSwitch = NSSwitch()
    private let alertsSwitch = NSSwitch()
    private var optimizationWindow: MemoryOptimizationWindowController?

    init(monitor: SystemMonitor, mascot: MascotWindowController) {
        self.monitor = monitor
        self.mascot = mascot
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 330, height: 650)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 610))

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 11
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 16)
        ])

        root.addArrangedSubview(makeHeader())
        root.addArrangedSubview(memoryRow)
        root.addArrangedSubview(cpuRow)
        root.addArrangedSubview(diskRow)
        root.addArrangedSubview(makeRule())

        let processTitle = NSTextField(labelWithString: "Memory-heavy apps")
        processTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(processTitle)
        processStack.orientation = .vertical
        processStack.alignment = .leading
        processStack.spacing = 5
        root.addArrangedSubview(processStack)
        root.addArrangedSubview(makeOptimizeButton())

        root.addArrangedSubview(makeRule())
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(chart)
        root.addArrangedSubview(makeRule())

        root.addArrangedSubview(makeToggleRow(title: "Floating buddy", control: floatingSwitch))
        root.addArrangedSubview(makeToggleRow(title: "Notify when strained", control: alertsSwitch))
        root.addArrangedSubview(makeFooter())

        floatingSwitch.target = self
        floatingSwitch.action = #selector(floatingChanged)
        alertsSwitch.target = self
        alertsSwitch.action = #selector(alertsChanged)
        update()
    }

    func update() {
        guard isViewLoaded else { return }
        statusLabel.stringValue = monitor.statusTitle
        statusLabel.textColor = monitor.statusColor
        statusDot.textColor = monitor.statusColor
        memoryRow.set(value: monitor.memorySummaryEnglish, detail: monitor.memoryDetail)
        cpuRow.set(value: monitor.cpuSummary, detail: "1-minute system load")
        diskRow.set(value: monitor.diskSummary, detail: "available on startup disk")
        chart.samples = monitor.history
        floatingSwitch.state = mascot.isVisible ? .on : .off
        alertsSwitch.state = monitor.alertsEnabled ? .on : .off
        rebuildProcesses()
    }

    @objc private func floatingChanged() {
        floatingSwitch.state == .on ? mascot.show() : mascot.hide()
    }

    @objc private func alertsChanged() {
        monitor.setAlertsEnabled(alertsSwitch.state == .on)
    }

    @objc private func refreshNow() {
        monitor.refresh(forceProcessList: true)
    }

    @objc private func quitMacBuddy() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func showMemoryOptimization() {
        if optimizationWindow == nil {
            let controller = MemoryOptimizationWindowController(monitor: monitor)
            controller.onClose = { [weak self] in self?.optimizationWindow = nil }
            optimizationWindow = controller
        }
        optimizationWindow?.present()
    }

    @objc private func requestProcessQuit(_ sender: NSButton) {
        guard let process = monitor.topProcesses.first(where: { $0.id == Int32(sender.tag) }) else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit \(process.name)?"
        alert.informativeText = "MacBuddy will request a normal app quit, never a force-quit. Unsaved work may need your confirmation."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.quit(process)
        }
    }

    private func rebuildProcesses() {
        for child in processStack.arrangedSubviews {
            processStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        guard !monitor.topProcesses.isEmpty else {
            let empty = NSTextField(labelWithString: "Collecting local process data…")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            processStack.addArrangedSubview(empty)
            return
        }

        for process in monitor.topProcesses.prefix(4) {
            processStack.addArrangedSubview(makeProcessRow(process))
        }
    }

    private func makeOptimizeButton() -> NSButton {
        let button = NSButton(title: "Optimize Memory…", target: self, action: #selector(showMemoryOptimization))
        button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 298).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let title = NSTextField(labelWithString: "MacBuddy")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12)
        statusDot.font = .systemFont(ofSize: 13)

        let labels = NSStackView(views: [title, statusLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(labels)
        container.addSubview(statusDot)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusDot.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            container.widthAnchor.constraint(equalToConstant: 298)
        ])
        return container
    }

    private func makeProcessRow(_ process: ProcessSnapshot) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.widthAnchor.constraint(equalToConstant: 298).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = monitor.statusColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: process.name)
        name.font = .systemFont(ofSize: 10.5)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: String(format: "%.0f MB · %.0f%%", process.memoryMB, process.cpu))
        detail.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        let quit = NSButton(title: "Quit", target: self, action: #selector(requestProcessQuit(_:)))
        quit.controlSize = .small
        quit.bezelStyle = .rounded
        quit.tag = Int(process.id)
        quit.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(icon)
        row.addSubview(name)
        row.addSubview(detail)
        row.addSubview(quit)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 5),
            detail.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quit.leadingAnchor.constraint(equalTo: detail.trailingAnchor, constant: 6),
            quit.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            quit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 100)
        ])
        return row
    }

    private func makeToggleRow(title: String, control: NSSwitch) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.widthAnchor.constraint(equalToConstant: 298).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        control.controlSize = .small
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeFooter() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        row.widthAnchor.constraint(equalToConstant: 298).isActive = true
        let refresh = NSButton(title: "Refresh now", target: self, action: #selector(refreshNow))
        let quit = NSButton(title: "Quit MacBuddy", target: self, action: #selector(quitMacBuddy))
        refresh.controlSize = .small
        quit.controlSize = .small
        refresh.translatesAutoresizingMaskIntoConstraints = false
        quit.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(refresh)
        row.addSubview(quit)
        NSLayoutConstraint.activate([
            refresh.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            refresh.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            quit.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func makeRule() -> NSBox {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 298).isActive = true
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }
}

@MainActor
private final class MetricRowView: NSView {
    private let titleLabel: NSTextField
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        widthAnchor.constraint(equalToConstant: 298).isActive = true

        titleLabel.font = .systemFont(ofSize: 12)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 9.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .right

        let values = NSStackView(views: [valueLabel, detailLabel])
        values.orientation = .vertical
        values.alignment = .trailing
        values.spacing = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        values.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(values)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            values.trailingAnchor.constraint(equalTo: trailingAnchor),
            values.centerYAnchor.constraint(equalTo: centerYAnchor),
            values.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(value: String, detail: String) {
        valueLabel.stringValue = value
        detailLabel.stringValue = detail
    }
}
