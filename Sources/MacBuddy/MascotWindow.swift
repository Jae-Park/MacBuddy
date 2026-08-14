import AppKit

@MainActor
final class MascotWindowController: NSObject {
    private let monitor: SystemMonitor
    private var panel: NSPanel?
    private var mascotView: MascotCanvasView?
    private let panelSize = NSSize(width: 156, height: 238)

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
    }

    func show() {
        if let panel {
            mascotView?.startAnimation()
            panel.orderFrontRegardless()
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
        mascotView.startAnimation()
        panel.orderFrontRegardless()
    }

    func hide() {
        mascotView?.stopAnimation()
        panel?.orderOut(nil)
    }

    @objc private func monitorDidUpdate() {
        mascotView?.refreshStatus()
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
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()

        if expanded { drawMessageBubble() }
        drawEnergyBar()
        drawMascot()
    }

    func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.52, target: self, selector: #selector(advanceIdleAnimation), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        blinkEndTimer?.invalidate()
        blinkEndTimer = nil
    }

    func refreshStatus() {
        updateAccessibility()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        animationTick = 0
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
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
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moved {
            dragging = false
            facing = .front
            verticalMotion = .idle
            step = false
        } else {
            expanded.toggle()
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let characterItem = NSMenuItem(title: "Character", action: nil, keyEquivalent: "")
        let characterMenu = NSMenu(title: "Character")

        for kind in CharacterKind.allCases {
            let item = NSMenuItem(title: kind.displayName, action: #selector(selectCharacter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = kind == character ? .on : .off
            characterMenu.addItem(item)
        }
        characterItem.submenu = characterMenu
        menu.addItem(characterItem)
        menu.addItem(.separator())

        let optimize = NSMenuItem(title: "Optimize Memory…", action: #selector(showMemoryOptimization), keyEquivalent: "")
        optimize.target = self
        menu.addItem(optimize)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About MacBuddy…", action: #selector(showAboutPanel), keyEquivalent: "")
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
        needsDisplay = true
        updateAccessibility()
    }

    @objc private func showAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "MacBuddy",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            .version: "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")",
            .applicationIcon: spritePack.icon(),
            .credits: NSAttributedString(
                string: "Created by Jaeyong Park\n\nA tiny pixel companion for macOS system health.",
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
            RunLoop.main.add(timer, forMode: .common)
            blinkEndTimer = timer
        }

        if !reduceMotion || blink { needsDisplay = true }
    }

    @objc private func endBlink() {
        blink = false
        needsDisplay = true
    }

    private func drawMessageBubble() {
        let rect = NSRect(x: 10, y: 58, width: 136, height: 56)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textRect = NSRect(x: 16, y: 67, width: 124, height: 40)
        (message as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }

    private func drawEnergyBar() {
        let outer = NSRect(x: 55, y: 120, width: 46, height: 9)
        NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.14, alpha: 0.92).setFill()
        outer.fill()
        monitor.energyColor.withAlphaComponent(0.45).setStroke()
        let outline = NSBezierPath(rect: outer.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        let filled = max(1, min(6, Int((monitor.energyLevel * 6).rounded(.up))))
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
        case .calm: "여유 있어\n\(monitor.memorySummary)"
        case .busy: "조금 무거워\n메뉴에서 앱 확인"
        case .strained: "정리가 필요해\n무거운 앱 확인"
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel("MacBuddy \(character.displayName), \(monitor.statusTitle)")
        setAccessibilityHelp("Click for status. Drag to move. Right-click to choose a character.")
    }

    private enum VerticalMotion {
        case idle, up, down
    }

    private enum CharacterFacing {
        case front, left, right
    }
}
