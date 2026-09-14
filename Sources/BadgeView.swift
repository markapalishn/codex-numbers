import AppKit

final class BadgeView: ClickableBadge {
    var usage: Usage? {
        didSet {
            needsDisplay = true
            updateFlameAnimation()
            let count = usage.map { Usage.exact($0.requestTokens) } ?? "—"
            let used = usage?.remainingLimit.map { "\(100 - $0)%" } ?? "—"
            setAccessibilityLabel("Запрос: \(count) токенов. Использовано лимита: \(used). Открыть аналитику")
        }
    }
    private var flameTimer: Timer?
    private var phase: Double = 0
    private var intensity: Double {
        guard let count = usage?.requestTokens, count > 0 else { return 0 }
        return max(0.08, min(1, (log10(Double(count)) - 3) / 3))
    }
    private func updateFlameAnimation() {
        let animate = intensity > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate { flameTimer?.invalidate(); flameTimer = nil; phase = 0; return }
        guard flameTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.flameTimer?.invalidate(); self.flameTimer = nil; self.phase = 0; self.needsDisplay = true; return
            }
            guard self.window?.isVisible == true else { return }
            self.phase += (0.07 + self.intensity * 0.08) * (self.usage?.running == true ? 1 : 0.55)
            self.setNeedsDisplay(NSRect(x: 12, y: 5, width: 39, height: 49))
        }
        flameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    deinit { flameTimer?.invalidate() }
    override var isFlipped: Bool { true }
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    static func preferredWidth(for usage: Usage) -> CGFloat {
        let width = (Usage.exact(usage.requestTokens) as NSString).size(withAttributes: [.font: numberFont]).width
        return max(400, ceil(width + 296))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        drawFlame()
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
    }
    private func drawFlame() {
        let strength = intensity
        let flicker = sin(phase) * (0.025 + strength * 0.04)
        let height = CGFloat(18 + 19 * strength + 1.3 * sin(phase * 1.7) * strength)
        let width = CGFloat(16 + 11 * strength)
        let origin = NSPoint(x: 31 - width / 2, y: 47 - height)
        func p(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: origin.x + CGFloat(x) * width, y: origin.y + CGFloat(y) * height)
        }
        let flame = NSBezierPath()
        flame.move(to: p(0.51 + flicker, 0))
        flame.curve(to: p(0.71, 0.45), controlPoint1: p(0.47, 0.23), controlPoint2: p(0.82 + flicker, 0.26))
        flame.curve(to: p(0.85, 0.30), controlPoint1: p(0.78, 0.45), controlPoint2: p(0.86, 0.38))
        flame.curve(to: p(0.98, 0.73), controlPoint1: p(0.85, 0.44), controlPoint2: p(1.02, 0.54))
        flame.curve(to: p(0.49, 1), controlPoint1: p(0.94, 0.92), controlPoint2: p(0.77, 1.02))
        flame.curve(to: p(0.03, 0.72), controlPoint1: p(0.20, 1.02), controlPoint2: p(0.01, 0.93))
        flame.curve(to: p(0.20, 0.39), controlPoint1: p(-0.03, 0.57), controlPoint2: p(0.15, 0.48))
        flame.curve(to: p(0.24, 0.58), controlPoint1: p(0.17, 0.48), controlPoint2: p(0.20, 0.54))
        flame.curve(to: p(0.51 + flicker, 0), controlPoint1: p(0.46, 0.41), controlPoint2: p(0.30 + flicker, 0.20))
        flame.close()
        let orange = NSColor(calibratedRed: 1, green: 0.55, blue: 0.15, alpha: 0.9)
        let red = NSColor(calibratedRed: 1, green: 0.25 + 0.10 * (1-strength), blue: 0.10, alpha: 1)
        NSGradient(starting: orange, ending: red)?.draw(in: flame, angle: 90)
        let core = NSBezierPath()
        core.move(to: p(0.53 - flicker * 0.6, 0.43))
        core.curve(to: p(0.73, 0.83), controlPoint1: p(0.48, 0.63), controlPoint2: p(0.79, 0.70))
        core.curve(to: p(0.28, 0.83), controlPoint1: p(0.70, 1.01), controlPoint2: p(0.30, 1.02))
        core.curve(to: p(0.53 - flicker * 0.6, 0.43), controlPoint1: p(0.22, 0.68), controlPoint2: p(0.45, 0.63))
        core.close()
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.92, blue: 0.60, alpha: 1), ending: .systemYellow)?.draw(in: core, angle: 90)
    }

}
