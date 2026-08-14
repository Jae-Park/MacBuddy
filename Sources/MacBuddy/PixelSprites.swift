import AppKit

enum CharacterKind: String, CaseIterable {
    case mint
    case chip
    case cake

    static let defaultsKey = "selectedCharacter"

    var displayName: String {
        switch self {
        case .mint: "Mint Buddy"
        case .chip: "Memory Chip"
        case .cake: "Strawberry Cake"
        }
    }

    static var selected: CharacterKind {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              let kind = CharacterKind(rawValue: value)
        else { return .mint }
        return kind
    }

    func select() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum SpriteFrame: Int {
    case front = 0
    case blink = 1
    case idleAlt = 2
    case side = 3
    case sideStep = 4
    case hover = 5
}

@MainActor
final class SpriteFramePack {
    let kind: CharacterKind
    private let sheet: NSImage?
    private static let frameSize: CGFloat = 48

    init(kind: CharacterKind) {
        self.kind = kind
        switch kind {
        case .mint: sheet = Self.load("macbuddy-mint-frames-48")
        case .chip: sheet = Self.load("macbuddy-chip-frames-48")
        case .cake: sheet = Self.load("macbuddy-cake-frames-48")
        }
    }

    func draw(frame: SpriteFrame, in destination: NSRect, flippedHorizontally: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false

        if flippedHorizontally {
            let transform = NSAffineTransform()
            transform.translateX(by: destination.midX * 2, yBy: 0)
            transform.scaleX(by: -1, yBy: 1)
            transform.concat()
        }

        if let sheet {
            let source = NSRect(
                x: CGFloat(frame.rawValue) * Self.frameSize,
                y: 0,
                width: Self.frameSize,
                height: Self.frameSize
            )
            sheet.draw(in: destination, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    func icon(size: CGFloat = 256) -> NSImage {
        let icon = NSImage(size: NSSize(width: size, height: size))
        icon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        let target = NSRect(x: 0, y: 0, width: size, height: size)
        if let sheet {
            sheet.draw(
                in: target,
                from: NSRect(x: 0, y: 0, width: Self.frameSize, height: Self.frameSize),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
        }
        icon.unlockFocus()
        return icon
    }

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
