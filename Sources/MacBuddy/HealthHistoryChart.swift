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

        (tr("Recent trend", "최근 추이") as NSString).draw(
            at: NSPoint(x: 0, y: 0),
            withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor]
        )
        let elapsed = max(samples.last?.timestamp.timeIntervalSince(samples.first?.timestamp ?? .now) ?? 0, 0)
        let durationText: String
        if elapsed < 60 {
            let seconds = max(Int(elapsed.rounded()), 1)
            durationText = tr("last \(seconds)s", "최근 \(seconds)초")
        } else {
            let minutes = max(Int((elapsed / 60).rounded()), 1)
            durationText = tr("last \(minutes)m", "최근 \(minutes)분")
        }
        let duration = durationText as NSString
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

        let points = Array(samples.suffix(450))
        drawTrend(points, in: chart, color: .systemMint) { $0.memoryFraction }
        drawTrend(points, in: chart, color: .systemOrange) { $0.cpuUsageFraction }

        drawLegend(color: .systemMint, text: tr("Memory pressure", "메모리 압력"), x: 0, y: 106, font: captionFont)
        drawLegend(color: .systemOrange, text: tr("CPU usage", "CPU 사용률"), x: 102, y: 106, font: captionFont)

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
        guard let firstTimestamp = points.first?.timestamp,
              let lastTimestamp = points.last?.timestamp
        else { return }
        let elapsed = max(lastTimestamp.timeIntervalSince(firstTimestamp), 0.001)
        let path = NSBezierPath()
        var previousTimestamp: Date?
        for point in points {
            let timeFraction = point.timestamp.timeIntervalSince(firstTimestamp) / elapsed
            let x = rect.minX + rect.width * CGFloat(min(max(timeFraction, 0), 1))
            let normalized = min(max(value(point), 0), 1)
            let y = rect.maxY - rect.height * normalized
            let hasGap = previousTimestamp.map { point.timestamp.timeIntervalSince($0) > 8 } ?? true
            if hasGap { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
            previousTimestamp = point.timestamp
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
        case .calm: return tr("steady", "안정")
        case .busy: return tr("watching", "관찰 중")
        case .strained: return tr("needs attention", "확인 필요")
        }
    }
}
