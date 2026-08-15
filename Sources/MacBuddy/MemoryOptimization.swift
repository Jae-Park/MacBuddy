import AppKit

struct MemoryOptimizationResult: Sendable {
    let requestedCount: Int
    let acceptedCount: Int
    let closedCount: Int
    let before: MemoryHealthSnapshot
    let after: MemoryHealthSnapshot

    var summary: String {
        let delta = after.headroomGB - before.headroomGB
        let deltaText = String(format: "%+.1f GB", delta)
        let quitText = tr(
            "Closed \(closedCount)/\(requestedCount) selected apps (\(acceptedCount) requests accepted).",
            "선택한 앱 \(requestedCount)개 중 \(closedCount)개를 종료했습니다(\(acceptedCount)개 요청 수락)."
        )
        return tr(
            "\(quitText) Headroom estimate \(before.headroomGB.oneDecimal) → \(after.headroomGB.oneDecimal) GB (\(deltaText)). Pressure \(before.pressure.title) → \(after.pressure.title). Swap \(before.swapGB.oneDecimal) → \(after.swapGB.oneDecimal) GB.",
            "\(quitText) 여유 추정치 \(before.headroomGB.oneDecimal) → \(after.headroomGB.oneDecimal) GB (\(deltaText)). 압력 \(before.pressure.title) → \(after.pressure.title). Swap \(before.swapGB.oneDecimal) → \(after.swapGB.oneDecimal) GB."
        )
    }
}

@MainActor
final class MemoryOptimizer {
    private let monitor: SystemMonitor
    private var running = false

    init(monitor: SystemMonitor) {
        self.monitor = monitor
    }

    func run(
        selected processes: [ProcessSnapshot],
        completion: @escaping @MainActor (MemoryOptimizationResult) -> Void
    ) {
        guard !running, !processes.isEmpty else { return }
        running = true
        let before = monitor.memoryHealthSnapshot

        let acceptedCount = processes.reduce(into: 0) { count, process in
            if monitor.quit(process) { count += 1 }
        }
        let pids = processes.map(\.id)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.monitor.refresh(forceProcessList: true)
            let closedCount = pids.filter { pid in
                NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true
            }.count
            let result = MemoryOptimizationResult(
                requestedCount: processes.count,
                acceptedCount: acceptedCount,
                closedCount: closedCount,
                before: before,
                after: self.monitor.memoryHealthSnapshot
            )
            self.running = false
            completion(result)
        }
    }
}

@MainActor
final class MemoryOptimizationWindowController: NSWindowController {
    private let optimizationViewController: MemoryOptimizationViewController
    var onClose: (() -> Void)?

    init(monitor: SystemMonitor) {
        optimizationViewController = MemoryOptimizationViewController(monitor: monitor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("Optimize Memory", "메모리 최적화")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentViewController = optimizationViewController
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.title = tr("Optimize Memory", "메모리 최적화")
        optimizationViewController.prepareForDisplay()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func languageDidChange() {
        window?.title = tr("Optimize Memory", "메모리 최적화")
    }
}

extension MemoryOptimizationWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

@MainActor
private final class MemoryOptimizationViewController: NSViewController {
    private let monitor: SystemMonitor
    private let optimizer: MemoryOptimizer
    private let currentStatus = NSTextField(wrappingLabelWithString: "")
    private let candidateStack = NSStackView()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let optimizeButton = NSButton(title: "", target: nil, action: nil)
    private var checkboxes: [Int32: NSButton] = [:]
    private var candidates: [ProcessSnapshot] = []
    private var candidateFingerprint = ""
    private var isRunning = false

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        self.optimizer = MemoryOptimizer(monitor: monitor)
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(monitorDidUpdate),
            name: .systemMonitorDidUpdate,
            object: monitor
        )
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 18)
        ])

        let title = NSTextField(labelWithString: tr("Optimize Memory", "메모리 최적화"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString: tr(
            "MacBuddy sends a normal Quit request only to apps you explicitly select. It never force-quits, purges RAM, or deletes caches.",
            "MacBuddy는 명시적으로 선택한 앱에만 일반 종료를 요청합니다. 강제 종료, RAM 강제 비우기, 캐시 삭제는 하지 않습니다."
        ))
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(explanation)

        currentStatus.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        currentStatus.textColor = .secondaryLabelColor
        currentStatus.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(currentStatus)

        let appHeader = NSTextField(labelWithString: tr("Apps you may quit", "종료할 수 있는 앱"))
        appHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(appHeader)
        root.addArrangedSubview(makeCandidateList())

        let selectionButtons = NSStackView(views: [
            NSButton(title: tr("Select all", "모두 선택"), target: self, action: #selector(selectAllCandidates(_:))),
            NSButton(title: tr("Clear", "선택 해제"), target: self, action: #selector(clearCandidateSelection(_:)))
        ])
        selectionButtons.orientation = NSUserInterfaceLayoutOrientation.horizontal
        selectionButtons.spacing = 8
        selectionButtons.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.controlSize = NSControl.ControlSize.small }
        root.addArrangedSubview(selectionButtons)

        let warning = NSTextField(wrappingLabelWithString: tr(
            "Finder, system services, MacBuddy, and the app you were using before opening this window are protected. Selected apps may ask you to save unsaved work.",
            "Finder, 시스템 서비스, MacBuddy와 이 창을 열기 전에 사용하던 앱은 보호됩니다. 선택한 앱에서 저장하지 않은 작업을 확인할 수 있습니다."
        ))
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = .secondaryLabelColor
        warning.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(warning)

        resultLabel.font = .systemFont(ofSize: 11, weight: .medium)
        resultLabel.textColor = .systemBlue
        resultLabel.preferredMaxLayoutWidth = 420
        resultLabel.stringValue = defaultResultMessage
        root.addArrangedSubview(resultLabel)

        root.addArrangedSubview(makeFooter())
        rebuildCandidates()
        updateCurrentStatus()
    }

    func prepareForDisplay() {
        loadViewIfNeeded()
        resultLabel.stringValue = defaultResultMessage
        monitor.refresh(forceProcessList: true)
        updateCurrentStatus()
        rebuildCandidates()
    }

    @objc private func monitorDidUpdate() {
        guard isViewLoaded else { return }
        updateCurrentStatus()
        if !isRunning, currentCandidateFingerprint != candidateFingerprint {
            rebuildCandidates()
        }
    }

    @objc private func appLanguageDidChange() {
        guard isViewLoaded, !isRunning else { return }
        loadView()
        updateCurrentStatus()
        rebuildCandidates()
    }

    @objc private func selectAllCandidates(_ sender: Any?) {
        checkboxes.values.forEach { $0.state = .on }
    }

    @objc private func clearCandidateSelection(_ sender: Any?) {
        checkboxes.values.forEach { $0.state = .off }
    }

    @objc private func runOptimization() {
        guard !isRunning else { return }
        let selected = candidates.filter { checkboxes[$0.id]?.state == .on }
        guard !selected.isEmpty else {
            resultLabel.textColor = .systemOrange
            resultLabel.stringValue = tr(
                "Select at least one app. MacBuddy never closes background apps automatically.",
                "앱을 하나 이상 선택하세요. MacBuddy는 백그라운드 앱을 자동으로 종료하지 않습니다."
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = tr("Run safe memory optimization?", "안전한 메모리 최적화를 실행할까요?")
        let names = selected.map(\.name).joined(separator: ", ")
        alert.informativeText = tr(
            "MacBuddy will send a normal Quit request to \(selected.count) selected app(s): \(names). Apps may ask you to save work.",
            "MacBuddy가 선택한 앱 \(selected.count)개에 일반 종료를 요청합니다: \(names). 저장하지 않은 작업을 확인할 수 있습니다."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Optimize", "최적화"))
        alert.addButton(withTitle: tr("Cancel", "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isRunning = true
        optimizeButton.isEnabled = false
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = tr("Optimizing… measuring again in 5 seconds.", "최적화 중… 5초 뒤 다시 측정합니다.")
        optimizer.run(selected: selected) { [weak self] result in
            guard let self else { return }
            self.isRunning = false
            self.optimizeButton.isEnabled = true
            let pressureImproved = result.after.pressure.healthStatus.severity < result.before.pressure.healthStatus.severity
            let pressureUnchanged = result.after.pressure == result.before.pressure
            self.resultLabel.textColor = pressureImproved || (pressureUnchanged && result.after.headroomGB >= result.before.headroomGB)
                ? .systemGreen
                : .systemOrange
            self.resultLabel.stringValue = result.summary
            self.updateCurrentStatus()
            self.rebuildCandidates()
        }
    }

    @objc private func closeWindow() {
        view.window?.close()
    }

    private func updateCurrentStatus() {
        currentStatus.stringValue = tr(
            "Now: \(monitor.memorySummary) · pressure \(monitor.memoryPressureState.title) · swap \(monitor.swapGB.oneDecimal) GB",
            "현재: \(monitor.memorySummary) · 압력 \(monitor.memoryPressureState.title) · swap \(monitor.swapGB.oneDecimal) GB"
        )
    }

    private func rebuildCandidates() {
        let selectedPIDs = Set(checkboxes.compactMap { $0.value.state == .on ? $0.key : nil })
        for child in candidateStack.arrangedSubviews {
            candidateStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        checkboxes.removeAll()
        candidates = Array(monitor.optimizationCandidates.prefix(8))
        candidateFingerprint = currentCandidateFingerprint

        guard !candidates.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: tr(
                "No eligible memory-heavy apps found. Refresh after opening the menu bar panel.",
                "종료할 수 있는 메모리 사용량 높은 앱이 없습니다. 메뉴바 패널을 연 뒤 새로고침하세요."
            ))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.preferredMaxLayoutWidth = 390
            candidateStack.addArrangedSubview(empty)
            return
        }

        for process in candidates {
            candidateStack.addArrangedSubview(makeCandidateRow(process, selected: selectedPIDs.contains(process.id)))
        }
    }

    private func makeCandidateList() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = 4
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(candidateStack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            candidateStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            candidateStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            candidateStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            candidateStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        return scroll
    }

    private func makeCandidateRow(_ process: ProcessSnapshot, selected: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 386).isActive = true
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let checkbox = NSButton(checkboxWithTitle: process.name, target: nil, action: nil)
        checkbox.state = selected ? .on : .off
        checkbox.font = .systemFont(ofSize: 11)
        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkboxes[process.id] = checkbox

        let detail = NSTextField(labelWithString: String(format: tr("%.0f MB · %.0f%% CPU (~1m avg)", "%.0f MB · %.0f%% CPU (~1분 평균)"), process.memoryMB, process.cpu))
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(checkbox)
        row.addSubview(detail)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: detail.leadingAnchor, constant: -8),
            detail.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            detail.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            checkbox.widthAnchor.constraint(lessThanOrEqualToConstant: 245)
        ])
        return row
    }

    private func makeFooter() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true

        optimizeButton.target = self
        optimizeButton.action = #selector(runOptimization)
        optimizeButton.title = tr("Run Safe Optimization", "안전하게 최적화")
        optimizeButton.bezelStyle = .rounded
        optimizeButton.keyEquivalent = "\r"
        optimizeButton.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: tr("Close", "닫기"), target: self, action: #selector(closeWindow))
        close.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(optimizeButton)
        row.addSubview(close)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            close.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            optimizeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            optimizeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private var defaultResultMessage: String {
        tr(
            "Choose one or more apps. Only selected apps receive a normal Quit request.",
            "앱을 하나 이상 선택하세요. 선택한 앱에만 일반 종료를 요청합니다."
        )
    }

    private var currentCandidateFingerprint: String {
        monitor.optimizationCandidates.prefix(8).map { process in
            "\(process.id):\(Int(process.memoryMB.rounded())):\(Int(process.cpu.rounded())):\(process.isProtected)"
        }.joined(separator: "|")
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
}
