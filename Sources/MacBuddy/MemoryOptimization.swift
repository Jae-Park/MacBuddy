import AppKit

struct MemoryOptimizationResult: Sendable {
    let requestedCount: Int
    let acceptedCount: Int
    let closedCount: Int
    let before: MemoryHealthSnapshot
    let after: MemoryHealthSnapshot

    var summary: String {
        let delta = after.availableGB - before.availableGB
        let deltaText = String(format: "%+.1f GB", delta)
        let quitText = requestedCount == 0
            ? "Safe background release completed."
            : "Closed \(closedCount)/\(requestedCount) selected apps (\(acceptedCount) requests accepted)."
        return "\(quitText) Available \(before.availableGB.oneDecimal) → \(after.availableGB.oneDecimal) GB (\(deltaText)). Pressure headroom \(Int(before.pressureFreePercent.rounded()))% → \(Int(after.pressureFreePercent.rounded()))%. Swap \(before.swapGB.oneDecimal) → \(after.swapGB.oneDecimal) GB."
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
        guard !running else { return }
        running = true
        let before = monitor.memoryHealthSnapshot

        NSRunningApplication.terminateAutomaticallyTerminableApplications()
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
        window.title = "Optimize Memory"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentViewController = optimizationViewController
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        optimizationViewController.prepareForDisplay()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
    private let optimizeButton = NSButton(title: "Run Safe Optimization", target: nil, action: nil)
    private var checkboxes: [Int32: NSButton] = [:]
    private var candidates: [ProcessSnapshot] = []
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

        let title = NSTextField(labelWithString: "Optimize Memory")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let explanation = NSTextField(wrappingLabelWithString: "MacBuddy releases only macOS-managed background apps and sends a normal Quit request to apps you select. It never force-quits, purges RAM, or deletes caches.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(explanation)

        currentStatus.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        currentStatus.textColor = .secondaryLabelColor
        currentStatus.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(currentStatus)

        let appHeader = NSTextField(labelWithString: "Apps you may quit")
        appHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(appHeader)
        root.addArrangedSubview(makeCandidateList())

        let selectionButtons = NSStackView(views: [
            NSButton(title: "Select all", target: self, action: #selector(selectAllCandidates(_:))),
            NSButton(title: "Clear", target: self, action: #selector(clearCandidateSelection(_:)))
        ])
        selectionButtons.orientation = NSUserInterfaceLayoutOrientation.horizontal
        selectionButtons.spacing = 8
        selectionButtons.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.controlSize = NSControl.ControlSize.small }
        root.addArrangedSubview(selectionButtons)

        let warning = NSTextField(wrappingLabelWithString: "Finder, system services, MacBuddy, and the app you were using before opening this window are protected. Selected apps may ask you to save unsaved work.")
        warning.font = .systemFont(ofSize: 10)
        warning.textColor = .secondaryLabelColor
        warning.preferredMaxLayoutWidth = 420
        root.addArrangedSubview(warning)

        resultLabel.font = .systemFont(ofSize: 11, weight: .medium)
        resultLabel.textColor = .systemBlue
        resultLabel.preferredMaxLayoutWidth = 420
        resultLabel.stringValue = "Choose apps, or run with no selection for the macOS-managed safe release only."
        root.addArrangedSubview(resultLabel)

        root.addArrangedSubview(makeFooter())
        rebuildCandidates()
        updateCurrentStatus()
    }

    func prepareForDisplay() {
        loadViewIfNeeded()
        resultLabel.stringValue = "Choose apps, or run with no selection for the macOS-managed safe release only."
        monitor.refresh(forceProcessList: true)
        updateCurrentStatus()
        rebuildCandidates()
    }

    @objc private func monitorDidUpdate() {
        guard isViewLoaded else { return }
        updateCurrentStatus()
        if !isRunning { rebuildCandidates() }
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

        let alert = NSAlert()
        alert.messageText = "Run safe memory optimization?"
        if selected.isEmpty {
            alert.informativeText = "MacBuddy will ask macOS to release only apps explicitly marked as automatically terminable."
        } else {
            let names = selected.map(\.name).joined(separator: ", ")
            alert.informativeText = "MacBuddy will send a normal Quit request to \(selected.count) selected app(s): \(names). Apps may ask you to save work."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Optimize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isRunning = true
        optimizeButton.isEnabled = false
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = "Optimizing… measuring again in 5 seconds."
        optimizer.run(selected: selected) { [weak self] result in
            guard let self else { return }
            self.isRunning = false
            self.optimizeButton.isEnabled = true
            self.resultLabel.textColor = result.after.pressureFreePercent >= result.before.pressureFreePercent ? .systemGreen : .systemOrange
            self.resultLabel.stringValue = result.summary
            self.updateCurrentStatus()
            self.rebuildCandidates()
        }
    }

    @objc private func closeWindow() {
        view.window?.close()
    }

    private func updateCurrentStatus() {
        currentStatus.stringValue = "Now: \(monitor.memorySummaryEnglish) · pressure headroom \(Int(monitor.memoryPressureFreePercent.rounded()))% · swap \(monitor.swapGB.oneDecimal) GB"
    }

    private func rebuildCandidates() {
        let selectedPIDs = Set(checkboxes.compactMap { $0.value.state == .on ? $0.key : nil })
        for child in candidateStack.arrangedSubviews {
            candidateStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        checkboxes.removeAll()
        candidates = Array(monitor.optimizationCandidates.prefix(8))

        guard !candidates.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No eligible memory-heavy apps found. Refresh after opening the menu bar panel, or run the safe background release only.")
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

        let detail = NSTextField(labelWithString: String(format: "%.0f MB · %.0f%% CPU", process.memoryMB, process.cpu))
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
        optimizeButton.bezelStyle = .rounded
        optimizeButton.keyEquivalent = "\r"
        optimizeButton.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
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
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
}
