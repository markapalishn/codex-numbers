import AppKit

final class BadgeView: ClickableBadge {
    var usage: Usage? {
        didSet {
            needsDisplay = true
            let count = usage.map { Usage.exact($0.requestTokens) } ?? "—"
            setAccessibilityLabel("Запрос: \(count) токенов. Открыть аналитику")
        }
    }
    override var isFlipped: Bool { true }
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    static func preferredWidth(for usage: Usage) -> CGFloat {
        let width = (Usage.exact(usage.requestTokens) as NSString).size(withAttributes: [.font: numberFont]).width
        return max(170, ceil(width + 95))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        text("Запрос", x: 22, y: 10, font: .systemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor)
        let count = usage.map { Usage.exact($0.requestTokens) } ?? "—"
        text(count, x: 21, y: 25, font: Self.numberFont, color: .labelColor)
        let numberWidth = (count as NSString).size(withAttributes: [.font: Self.numberFont]).width
        text("токенов", x: 27 + numberWidth, y: 32, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    }
}
