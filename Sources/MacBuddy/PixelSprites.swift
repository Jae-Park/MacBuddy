import AppKit
import ImageIO

enum CharacterKind: String, CaseIterable {
    case mint
    case chip
    case cake

    static let defaultsKey = "selectedCharacter"

    var displayName: String {
        switch self {
        case .mint: tr("Mint Buddy", "민트 버디")
        case .chip: tr("Memory Chip", "메모리 칩")
        case .cake: tr("Strawberry Cake", "딸기 케이크")
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

enum SpriteFrame: Int, CaseIterable {
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
    private let frames: [SpriteFrame: NSImage]
    private static let frameSize: CGFloat = 48

    init(kind: CharacterKind) {
        self.kind = kind
        switch kind {
        case .mint: frames = Self.loadFrames("macbuddy-mint-frames-48")
        case .chip: frames = Self.loadFrames("macbuddy-chip-frames-48")
        case .cake: frames = Self.loadFrames("macbuddy-cake-frames-48")
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

        if let image = frames[frame] {
            image.draw(
                in: destination,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    func icon(size: CGFloat = 256) -> NSImage {
        let icon = NSImage(size: NSSize(width: size, height: size))
        icon.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.shouldAntialias = false
        let target = NSRect(x: 0, y: 0, width: size, height: size)
        if let image = frames[.front] {
            image.draw(
                in: target,
                from: NSRect(origin: .zero, size: image.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
        }
        icon.unlockFocus()
        return icon
    }

    private static func loadFrames(_ name: String) -> [SpriteFrame: NSImage] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceShouldCache: true
              ] as CFDictionary)
        else { return [:] }

        return SpriteFrame.allCases.reduce(into: [:]) { result, frame in
            let sourceRect = CGRect(
                x: CGFloat(frame.rawValue) * frameSize,
                y: 0,
                width: frameSize,
                height: frameSize
            )
            guard let cropped = sheet.cropping(to: sourceRect) else { return }
            let image = NSImage(cgImage: cropped, size: NSSize(width: frameSize, height: frameSize))
            image.cacheMode = .never
            result[frame] = image
        }
    }
}
