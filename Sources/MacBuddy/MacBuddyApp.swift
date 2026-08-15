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
    private var renderedStatus: HealthStatus?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
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

    @objc private func languageDidChange() {
        updateStatusIcon(force: true)
    }

    func popoverWillClose(_ notification: Notification) {
        monitor.dashboardClosed()
    }

    private func updateStatusIcon(force: Bool = false) {
        guard let button = statusItem.button else { return }
        guard force || renderedStatus != monitor.status else { return }
        renderedStatus = monitor.status
        let image = NSImage(systemSymbolName: monitor.statusSymbol, accessibilityDescription: monitor.statusTitle)
            ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: monitor.statusTitle)
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "●" : ""
        button.imagePosition = image == nil ? .noImage : .imageOnly
        button.setAccessibilityLabel("MacBuddy, \(monitor.statusTitle)")
    }
}

@MainActor
private final class DashboardViewController: NSViewController {
    private let monitor: SystemMonitor
    private let mascot: MascotWindowController

    private let statusLabel = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let memoryRow = MetricRowView(title: "")
    private let cpuRow = MetricRowView(title: "")
    private let diskRow = MetricRowView(title: "")
    private let processStack = NSStackView()
    private let processEmptyLabel = NSTextField(labelWithString: "")
    private var processRows: [ProcessRowView] = []
    private let chart = HealthHistoryChartView()
    private let floatingSwitch = NSSwitch()
    private let alertsSwitch = NSSwitch()
    private let languagePopup = NSPopUpButton()
    private var optimizationWindow: MemoryOptimizationWindowController?

    init(monitor: SystemMonitor, mascot: MascotWindowController) {
        self.monitor = monitor
        self.mascot = mascot
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 330, height: 680)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLanguageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 650))

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

        let processTitle = NSTextField(labelWithString: tr("Memory-heavy apps", "메모리를 많이 쓰는 앱"))
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

        root.addArrangedSubview(makeToggleRow(title: tr("Floating buddy", "플로팅 버디"), control: floatingSwitch))
        root.addArrangedSubview(makeToggleRow(title: tr("Notify when strained", "상태가 나쁠 때 알림"), control: alertsSwitch))
        root.addArrangedSubview(makeLanguageRow())
        root.addArrangedSubview(makeFooter())

        floatingSwitch.target = self
        floatingSwitch.action = #selector(floatingChanged)
        alertsSwitch.target = self
        alertsSwitch.action = #selector(alertsChanged)
        update()
    }

    func update() {
        guard isViewLoaded else { return }
        memoryRow.setTitle(tr("Memory", "메모리"))
        cpuRow.setTitle(tr("CPU usage", "CPU 사용률"))
        diskRow.setTitle(tr("Disk", "디스크"))
        statusLabel.stringValue = monitor.statusTitle
        statusLabel.textColor = monitor.statusColor
        statusDot.textColor = monitor.statusColor
        memoryRow.set(value: monitor.memorySummary, detail: monitor.memoryDetail)
        cpuRow.set(value: monitor.cpuSummary, detail: tr("Current system usage", "현재 시스템 사용률"))
        diskRow.set(value: monitor.diskSummary, detail: tr("available on startup disk", "시동 디스크 여유 공간"))
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

    @objc private func languageSelectionChanged() {
        guard let rawValue = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else { return }
        language.select()
    }

    @objc private func appLanguageDidChange() {
        guard isViewLoaded else { return }
        loadView()
        update()
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
        guard let process = monitor.topProcesses.first(where: { $0.id == Int32(sender.tag) }),
              process.isRegularApplication,
              !process.isProtected
        else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("Quit \(process.name)?", "\(process.name)을(를) 종료할까요?")
        alert.informativeText = tr(
            "MacBuddy will request a normal app quit, never a force-quit. Unsaved work may need your confirmation.",
            "MacBuddy는 강제 종료가 아닌 일반 종료만 요청합니다. 저장하지 않은 작업이 있다면 확인이 필요할 수 있습니다."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Quit", "종료"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.quit(process)
        }
    }

    private func rebuildProcesses() {
        if processRows.isEmpty {
            for _ in 0..<4 {
                let row = ProcessRowView(target: self, action: #selector(requestProcessQuit(_:)))
                processRows.append(row)
                processStack.addArrangedSubview(row)
            }
            processEmptyLabel.font = .systemFont(ofSize: 11)
            processEmptyLabel.textColor = .secondaryLabelColor
            processStack.addArrangedSubview(processEmptyLabel)
        }

        let processes = Array(monitor.topProcesses.prefix(4))
        processEmptyLabel.stringValue = tr("Collecting local process data…", "로컬 프로세스 정보를 수집하는 중…")
        processEmptyLabel.isHidden = !processes.isEmpty
        for (index, row) in processRows.enumerated() {
            row.configure(
                process: index < processes.count ? processes[index] : nil,
                tintColor: monitor.statusColor
            )
        }
    }

    private func makeOptimizeButton() -> NSButton {
        let button = NSButton(title: tr("Optimize Memory…", "메모리 최적화…"), target: self, action: #selector(showMemoryOptimization))
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

    private func makeLanguageRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        row.widthAnchor.constraint(equalToConstant: 298).isActive = true

        let label = NSTextField(labelWithString: tr("Language", "언어"))
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false

        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.menuTitle)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(where: { ($0.representedObject as? String) == AppLanguage.selected.rawValue })
        languagePopup.target = self
        languagePopup.action = #selector(languageSelectionChanged)
        languagePopup.controlSize = .small
        languagePopup.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(label)
        row.addSubview(languagePopup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            languagePopup.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            languagePopup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 138)
        ])
        return row
    }

    private func makeFooter() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        row.widthAnchor.constraint(equalToConstant: 298).isActive = true
        let refresh = NSButton(title: tr("Refresh now", "지금 새로고침"), target: self, action: #selector(refreshNow))
        let quit = NSButton(title: tr("Quit MacBuddy", "MacBuddy 종료"), target: self, action: #selector(quitMacBuddy))
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
private final class ProcessRowView: NSView {
    private let icon = NSImageView(
        image: NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil) ?? NSImage()
    )
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let quitButton: NSButton

    init(target: AnyObject?, action: Selector) {
        quitButton = NSButton(title: "", target: target, action: action)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        widthAnchor.constraint(equalToConstant: 298).isActive = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 10.5)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        quitButton.controlSize = .small
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(quitButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 5),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            quitButton.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 6),
            quitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 100)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(process: ProcessSnapshot?, tintColor: NSColor) {
        guard let process else {
            isHidden = true
            return
        }

        isHidden = false
        icon.contentTintColor = tintColor
        nameLabel.stringValue = process.name
        detailLabel.stringValue = String(format: "%.0f MB · %.0f%% ~1m", process.memoryMB, process.cpu)
        quitButton.title = tr("Quit", "종료")
        quitButton.tag = Int(process.id)
        quitButton.isEnabled = process.isRegularApplication && !process.isProtected
        quitButton.toolTip = quitButton.isEnabled
            ? nil
            : tr(
                "Protected or ambiguous app instance",
                "보호된 앱 또는 구분할 수 없는 앱 인스턴스"
            )
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

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }
}

private extension NSPopUpButton {
    func selectItem(where predicate: (NSMenuItem) -> Bool) {
        guard let item = itemArray.first(where: predicate) else { return }
        select(item)
    }
}
