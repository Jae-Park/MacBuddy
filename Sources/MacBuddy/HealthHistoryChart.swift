import AppKit

@MainActor
final class HealthHistoryChartView: NSView {
    var samples: [HealthSample] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 122) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let captionFont = NSFont.systemFont(ofSize: 10)
        let secondary = NSColor.secondaryLabelColor

        ("Recent trend" as NSString).draw(
            at: NSPoint(x: 0, y: 0),
            withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor]
        )
        let minutes = max(samples.count * 12 / 60, 1)
        let duration = "last \(minutes)m" as NSString
        let durationSize = duration.size(withAttributes: [.font: captionFont])
        duration.draw(
            at: NSPoint(x: bounds.maxX - durationSize.width, y: 2),
            withAttributes: [.font: captionFont, .foregroundColor: secondary]
        )

        let chart = NSRect(x: 0, y: 24, width: bounds.width, height: 72)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: chart, xRadius: 8, yRadius: 8).fill()

        secondary.withAlphaComponent(0.16).setStroke()
        for fraction in [0.25, 0.5, 0.75] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: chart.minX, y: chart.minY + chart.height * fraction))
            line.line(to: NSPoint(x: chart.maxX, y: chart.minY + chart.height * fraction))
            line.lineWidth = 1
            line.stroke()
        }

        let points = Array(samples.suffix(150))
        drawTrend(points, in: chart, color: .systemMint) { $0.memoryFraction }
        drawTrend(points, in: chart, color: .systemOrange) { $0.cpuLoad / 10 }

        drawLegend(color: .systemMint, text: "Memory pressure", x: 0, y: 106, font: captionFont)
        drawLegend(color: .systemOrange, text: "CPU load", x: 102, y: 106, font: captionFont)

        let hint = monitoringHint as NSString
        let hintSize = hint.size(withAttributes: [.font: captionFont])
        hint.draw(
            at: NSPoint(x: bounds.maxX - hintSize.width, y: 105),
            withAttributes: [.font: captionFont, .foregroundColor: secondary]
        )
    }

    private func drawTrend(
        _ points: [HealthSample],
        in rect: NSRect,
        color: NSColor,
        value: (HealthSample) -> Double
    ) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let normalized = min(max(value(point), 0), 1)
            let y = rect.maxY - rect.height * normalized
            if index == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }
        color.setStroke()
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawLegend(color: NSColor, text: String, x: CGFloat, y: CGFloat, font: NSFont) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y + 3, width: 5, height: 5)).fill()
        (text as NSString).draw(
            at: NSPoint(x: x + 9, y: y),
            withAttributes: [.font: font, .foregroundColor: color]
        )
    }

    private var monitoringHint: String {
        guard let latest = samples.last else { return "" }
        switch latest.status {
        case .calm: return "steady"
        case .busy: return "watching"
        case .strained: return "needs attention"
        }
    }
}
