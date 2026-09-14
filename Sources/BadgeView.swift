import AppKit

final class BadgeView: ClickableBadge {
    var usage: Usage? {
        didSet {
            needsDisplay = true
            let count = usage.map { Usage.exact($0.requestTokens) } ?? "—"
            let used = usage?.remainingLimit.map { "\(100 - $0)%" } ?? "—"
            setAccessibilityLabel("Запрос: \(count) токенов. Использовано лимита: \(used). Открыть аналитику")
        }
    }
    var tracking: NSTrackingArea?
    var hovered = false
    override var isFlipped: Bool { true }
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    static func preferredWidth(for usage: Usage) -> CGFloat {
        let width = (Usage.exact(usage.requestTokens) as NSString).size(withAttributes: [.font: numberFont]).width
        return max(400, ceil(width + 296))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        let accent = NSColor.controlAccentColor
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        let iconRect = NSRect(x: 16, y: 15, width: 30, height: 30)
        accent.withAlphaComponent(hovered ? 0.17 : 0.10).setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: 11, yRadius: 11).fill()
        // A quiet three-bar mark doubles as the entry point to usage analytics.
        accent.withAlphaComponent(0.9).setFill()
        for (index, height) in [CGFloat(7), 15, 11].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 23 + CGFloat(index)*6, y: 37-height, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
        text(usage?.running == true ? "Запрос · в работе" : "Запрос", x: 58, y: 10, font: small, color: .secondaryLabelColor)
        let count = usage.map { Usage.exact($0.requestTokens) } ?? "—"
        text(count, x: 57, y: 25, font: Self.numberFont, color: .labelColor)
        let numberWidth = (count as NSString).size(withAttributes: [.font: Self.numberFont]).width
        text("токенов", x: 63 + numberWidth, y: 32, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)

        let dividerX = bounds.width - 160
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: dividerX, y: 17, width: 1, height: 26), xRadius: 0.5, yRadius: 0.5).fill()
        let ringX = dividerX + 17
        let ring = NSBezierPath(ovalIn: NSRect(x: ringX, y: 22, width: 16, height: 16))
        ring.lineWidth = 2.5
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke(); ring.stroke()
        let remaining = usage?.remainingLimit
        let used = remaining.map { 100 - $0 }
        let limitColor: NSColor = remaining.map { $0 <= 10 ? .systemRed : ($0 <= 25 ? .systemOrange : .systemTeal) } ?? .secondaryLabelColor
        if let used, used > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = 2.5; arc.lineCapStyle = .round
            arc.appendArc(withCenter: NSPoint(x: ringX+8, y: 30), radius: 8, startAngle: -90, endAngle: -90 + 360 * CGFloat(used)/100, clockwise: false)
            limitColor.setStroke(); arc.stroke()
        }
        text("Использовано", x: ringX + 28, y: 10, font: small, color: .secondaryLabelColor)
        text(used.map { "\($0)%" } ?? "—", x: ringX + 27, y: 25, font: Self.numberFont, color: .labelColor)
        let arrowX = bounds.width - 17
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: arrowX-3, y: 27))
        arrow.line(to: NSPoint(x: arrowX, y: 30))
        arrow.line(to: NSPoint(x: arrowX-3, y: 33))
        (hovered ? accent : NSColor.tertiaryLabelColor).setStroke(); arrow.stroke()
    }
}
