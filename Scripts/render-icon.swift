#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: render-icon.swift SPRITE_SHEET OUTPUT_PNG\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let sheet = NSImage(contentsOf: sourceURL) else {
    fputs("Could not load sprite sheet.\n", stderr)
    exit(1)
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create icon canvas.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .none
context.shouldAntialias = true

let background = NSRect(x: 64, y: 64, width: 896, height: 896)
NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.17, alpha: 1).setFill()
NSBezierPath(roundedRect: background, xRadius: 210, yRadius: 210).fill()

context.shouldAntialias = false
sheet.draw(
    in: NSRect(x: 176, y: 176, width: 672, height: 672),
    from: NSRect(x: 0, y: 0, width: 48, height: 48),
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: nil
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not render icon.\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
