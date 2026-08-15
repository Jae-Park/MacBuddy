import AppKit

@MainActor
final class MascotWindowController: NSObject {
    private let monitor: SystemMonitor
    private var panel: NSPanel?
    private var mascotView: MascotCanvasView?
    private let panelSize = NSSize(width: 156, height: 238)
    private var sessionActive = true
    private var screensAwake = true

    var isVisible: Bool { panel?.isVisible == true }

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        super.init()
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
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            updateAnimationState()
            DispatchQueue.main.async { [weak self] in self?.updateAnimationState() }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let mascotView = MascotCanvasView(frame: NSRect(origin: .zero, size: panelSize), monitor: monitor)
        panel.contentView = mascotView

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 176, y: visible.minY + 42))
        }

        self.panel = panel
        self.mascotView = mascotView
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: panel
        )
        panel.orderFrontRegardless()
        updateAnimationState()
        DispatchQueue.main.async { [weak self] in self?.updateAnimationState() }
    }

    func hide() {
        panel?.orderOut(nil)
        updateAnimationState()
    }

    @objc private func monitorDidUpdate() {
        mascotView?.refreshStatus()
    }

    @objc private func languageDidChange() {
        mascotView?.refreshStatus(forceText: true)
    }

    @objc private func sessionDidResignActive() {
        sessionActive = false
        updateAnimationState()
    }

    @objc private func sessionDidBecomeActive() {
        sessionActive = true
        updateAnimationState()
    }

    @objc private func screensDidSleep() {
        screensAwake = false
        updateAnimationState()
    }

    @objc private func screensDidWake() {
        screensAwake = true
        updateAnimationState()
    }

    @objc private func windowOcclusionDidChange() {
        updateAnimationState()
    }

    private func updateAnimationState() {
        guard let panel, panel.isVisible,
              panel.occlusionState.contains(.visible),
              sessionActive,
              screensAwake
        else {
            mascotView?.stopAnimation()
            return
        }
        mascotView?.startAnimation()
    }
}

@MainActor
private final class MascotCanvasView: NSView {
    private let monitor: SystemMonitor
    private var character = CharacterKind.selected
    private var spritePack: SpriteFramePack
    private var expanded = false
    private var hovering = false
    private var dragging = false
    private var facing: CharacterFacing = .front
    private var verticalMotion: VerticalMotion = .idle
    private var blink = false
    private var idleBounce = false
    private var step = false
    private var animationTick = 0
    private var animationTimer: Timer?
    private var blinkEndTimer: Timer?
    private var optimizationWindow: MemoryOptimizationWindowController?
    private var lastRenderedStatus: HealthStatus?
    private var lastRenderedEnergySegments: Int?
    private var lastRenderedMessage: String?

    private static let bubbleDrawRect = NSRect(x: 8, y: 56, width: 140, height: 60)
    private static let energyDrawRect = NSRect(x: 53, y: 118, width: 50, height: 13)
    private static let mascotDrawRect = NSRect(x: 32, y: 133, width: 92, height: 96)
    private let messageBubblePath = NSBezierPath(
        roundedRect: NSRect(x: 10, y: 58, width: 136, height: 56),
        xRadius: 14,
        yRadius: 14
    )
    private let energyOutlinePath = NSBezierPath(
        rect: NSRect(x: 55, y: 120, width: 46, height: 9).insetBy(dx: 0.5, dy: 0.5)
    )
    private lazy var messageAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        return [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
    }()

    private var startMouse = NSPoint.zero
    private var lastMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var moved = false
    private var strideDistance: CGFloat = 0

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, monitor: SystemMonitor) {
        self.monitor = monitor
        self.spritePack = SpriteFramePack(kind: CharacterKind.selected)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.magnificationFilter = .nearest
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
        lastRenderedStatus = monitor.status
        lastRenderedEnergySegments = energySegments
        lastRenderedMessage = message
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        dirtyRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        if expanded, dirtyRect.intersects(Self.bubbleDrawRect) { drawMessageBubble() }
        if dirtyRect.intersects(Self.energyDrawRect) { drawEnergyBar() }
        if dirtyRect.intersects(Self.mascotDrawRect) { drawMascot() }
    }

    func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.52, target: self, selector: #selector(advanceIdleAnimation), userInfo: nil, repeats: true)
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        blinkEndTimer?.invalidate()
        blinkEndTimer = nil
    }

    func refreshStatus(forceText: Bool = false) {
        let currentStatus = monitor.status
        let currentSegments = energySegments
        let currentMessage = message
        let statusChanged = currentStatus != lastRenderedStatus

        if forceText || statusChanged {
            updateAccessibility()
        }
        if statusChanged || currentSegments != lastRenderedEnergySegments {
            setNeedsDisplay(Self.energyDrawRect)
        }
        if expanded, forceText || currentMessage != lastRenderedMessage {
            setNeedsDisplay(Self.bubbleDrawRect)
        }

        lastRenderedStatus = currentStatus
        lastRenderedEnergySegments = currentSegments
        lastRenderedMessage = currentMessage
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        animationTick = 0
        setNeedsDisplay(Self.mascotDrawRect)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        setNeedsDisplay(Self.mascotDrawRect)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        lastMouse = startMouse
        startOrigin = window?.frame.origin ?? .zero
        moved = false
        strideDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let total = NSSize(width: current.x - startMouse.x, height: current.y - startMouse.y)
        let delta = NSSize(width: current.x - lastMouse.x, height: current.y - lastMouse.y)

        if abs(total.width) > 2 || abs(total.height) > 2 { moved = true }
        window.setFrameOrigin(NSPoint(x: startOrigin.x + total.width, y: startOrigin.y + total.height))

        dragging = true
        if abs(delta.width) > abs(delta.height) {
            facing = delta.width < 0 ? .left : .right
            verticalMotion = .idle
        } else if abs(delta.height) > 0.25 {
            facing = .front
            verticalMotion = delta.height > 0 ? .up : .down
        }

        strideDistance += abs(delta.width) + abs(delta.height)
        if strideDistance >= 5 {
            step.toggle()
            strideDistance = 0
        }
        lastMouse = current
        setNeedsDisplay(Self.mascotDrawRect)
    }

    override func mouseUp(with event: NSEvent) {
        if moved {
            dragging = false
            facing = .front
            verticalMotion = .idle
            step = false
            setNeedsDisplay(Self.mascotDrawRect)
        } else {
            expanded.toggle()
            setNeedsDisplay(Self.bubbleDrawRect)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let characterTitle = tr("Character", "캐릭터")
        let characterItem = NSMenuItem(title: characterTitle, action: nil, keyEquivalent: "")
        let characterMenu = NSMenu(title: characterTitle)

        for kind in CharacterKind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(selectCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == character ? .on : .off
            characterMenu.addItem(item)
        }
        characterItem.submenu = characterMenu
        menu.addItem(characterItem)

        let languageTitle = tr("Language", "언어")
        let languageItem = NSMenuItem(title: languageTitle, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: languageTitle)
        for language in AppLanguage.allCases {
            let item = NSMenuItem(title: language.menuTitle, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == AppLanguage.selected ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        menu.addItem(.separator())

        let optimize = NSMenuItem(title: tr("Optimize Memory…", "메모리 최적화…"), action: #selector(showMemoryOptimization), keyEquivalent: "")
        optimize.target = self
        menu.addItem(optimize)
        menu.addItem(.separator())

        let about = NSMenuItem(title: tr("About MacBuddy…", "MacBuddy 정보…"), action: #selector(showAboutPanel), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func selectCharacter(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selected = CharacterKind(rawValue: rawValue),
              selected != character
        else { return }

        selected.select()
        character = selected
        spritePack = SpriteFramePack(kind: selected)
        blink = false
        step = false
        facing = .front
        setNeedsDisplay(Self.mascotDrawRect)
        updateAccessibility()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else { return }
        language.select()
    }

    @objc private func showAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "MacBuddy",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            .version: "\(tr("Build", "빌드")) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")",
            .applicationIcon: spritePack.icon(),
            .credits: NSAttributedString(
                string: "Created by Jaeyong Park\nA tiny pixel companion for your Mac.",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            )
        ]
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func showMemoryOptimization() {
        if optimizationWindow == nil {
            let controller = MemoryOptimizationWindowController(monitor: monitor)
            controller.onClose = { [weak self] in self?.optimizationWindow = nil }
            optimizationWindow = controller
        }
        optimizationWindow?.present()
    }

    @objc private func advanceIdleAnimation() {
        guard !dragging else { return }
        animationTick += 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion { idleBounce.toggle() }

        let blinkInterval = hovering ? 3 : 7
        if animationTick % blinkInterval == 0 {
            blink = true
            blinkEndTimer?.invalidate()
            let timer = Timer(timeInterval: 0.14, target: self, selector: #selector(endBlink), userInfo: nil, repeats: false)
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            blinkEndTimer = timer
        }

        if !reduceMotion || blink { setNeedsDisplay(Self.mascotDrawRect) }
    }

    @objc private func endBlink() {
        blink = false
        setNeedsDisplay(Self.mascotDrawRect)
    }

    private func drawMessageBubble() {
        NSColor.black.withAlphaComponent(0.76).setFill()
        messageBubblePath.fill()
        let textRect = NSRect(x: 16, y: 67, width: 124, height: 40)
        (message as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: messageAttributes)
    }

    private func drawEnergyBar() {
        let outer = NSRect(x: 55, y: 120, width: 46, height: 9)
        NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.14, alpha: 0.92).setFill()
        outer.fill()
        monitor.energyColor.withAlphaComponent(0.45).setStroke()
        energyOutlinePath.lineWidth = 1
        energyOutlinePath.stroke()

        let filled = energySegments
        for index in 0..<6 {
            let segment = NSRect(x: 57 + CGFloat(index * 7), y: 122.5, width: 6, height: 4)
            (index < filled ? monitor.energyColor : NSColor.white.withAlphaComponent(0.14)).setFill()
            segment.fill()
        }
    }

    private func drawMascot() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var destination = NSRect(x: 36, y: 139, width: 84, height: 84)

        if !reduceMotion, !dragging, idleBounce { destination.origin.y -= 2 }
        switch verticalMotion {
        case .idle: break
        case .up: destination.origin.y -= 4
        case .down: destination.origin.y += 4
        }

        let frame: SpriteFrame
        switch facing {
        case .front:
            if blink {
                frame = .blink
            } else if hovering, !reduceMotion {
                frame = .hover
            } else if idleBounce, !reduceMotion {
                frame = .idleAlt
            } else {
                frame = .front
            }
        case .left, .right: frame = step ? .sideStep : .side
        }
        spritePack.draw(frame: frame, in: destination, flippedHorizontally: facing == .right)
    }

    private var message: String {
        switch monitor.status {
        case .calm: tr("All clear\n\(monitor.memorySummary)", "여유 있어\n\(monitor.memorySummary)")
        case .busy, .strained:
            switch monitor.dominantLoadCause {
            case .cpu: tr("CPU load high\nMemory is okay", "CPU 사용량 높음\n메모리는 여유 있어")
            case .memory: tr("Memory pressure\nCheck heavy apps", "메모리 압력 높음\n무거운 앱 확인")
            case .both: tr("System load high\nCPU + memory", "시스템 부하 높음\nCPU + 메모리")
            }
        }
    }

    private var energySegments: Int {
        max(1, min(6, Int((monitor.energyLevel * 6).rounded())))
    }

    private func updateAccessibility() {
        setAccessibilityLabel("MacBuddy \(character.displayName), \(monitor.statusTitle)")
        setAccessibilityHelp(tr(
            "Click for status. Drag to move. Right-click for options.",
            "클릭하면 상태를 보고, 드래그하면 옮길 수 있습니다. 우클릭하면 옵션이 열립니다."
        ))
    }

    private enum VerticalMotion {
        case idle, up, down
    }

    private enum CharacterFacing {
        case front, left, right
    }
}
