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
        let count = Double(usage?.requestTokens ?? 0)
        guard count > 0 else { return 0 }
        let stops: [(Double, Double)] = [(0, 0.02), (25_000, 0.18), (100_000, 0.48), (300_000, 0.82), (1_000_000, 1)]
        for index in 1..<stops.count where count <= stops[index].0 {
            let a = stops[index-1], b = stops[index]
            return a.1 + (b.1-a.1) * (count-a.0) / (b.0-a.0)
        }
        return 1
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
            self.phase += 0.10 + self.intensity * 0.15
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
        guard strength > 0 else {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 29, width: 10, height: 2), xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        let sway = sin(phase) * (0.08 + strength * 0.09)
        let bounce = sin(phase * 1.9)
        let height = CGFloat(10 + 16 * strength + bounce * strength)
        let width = CGFloat(9 + 12 * strength - bounce * strength * 0.5)
        let origin = NSPoint(x: 31 - width / 2, y: 30 - height / 2)
        func p(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: origin.x + CGFloat(x) * width, y: origin.y + CGFloat(y) * height)
        }
        // Rounded, layered vector silhouette with independent moving tongues.
        let flame = NSBezierPath()
        flame.move(to: p(0.53 + sway, 0))
        flame.curve(to: p(0.79, 0.44), controlPoint1: p(0.48 + sway, 0.22), controlPoint2: p(0.86, 0.27))
        flame.curve(to: p(0.86, 0.27 + 0.05*sin(phase*1.4)), controlPoint1: p(0.90, 0.41), controlPoint2: p(0.87, 0.32))
        flame.curve(to: p(0.98, 0.76), controlPoint1: p(0.93, 0.45), controlPoint2: p(1.07, 0.59))
        flame.curve(to: p(0.51, 1), controlPoint1: p(0.94, 0.95), controlPoint2: p(0.74, 1.03))
        flame.curve(to: p(0.03, 0.77), controlPoint1: p(0.25, 1.03), controlPoint2: p(0.04, 0.95))
        flame.curve(to: p(0.17, 0.33 + 0.05*cos(phase)), controlPoint1: p(-0.07, 0.57), controlPoint2: p(0.15, 0.46))
        flame.curve(to: p(0.24, 0.56), controlPoint1: p(0.15, 0.45), controlPoint2: p(0.17, 0.53))
        flame.curve(to: p(0.53 + sway, 0), controlPoint1: p(0.42, 0.35), controlPoint2: p(0.28 + sway, 0.15))
        flame.close()
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.24, blue: 0.08, alpha: 1),
                   ending: NSColor(calibratedRed: 1, green: 0.58, blue: 0.07, alpha: 1))?.draw(in: flame, angle: 90)
        let heart = NSBezierPath()
        heart.move(to: p(0.52 - sway*0.6, 0.30))
        heart.curve(to: p(0.75, 0.66), controlPoint1: p(0.46, 0.48), controlPoint2: p(0.76, 0.47))
        heart.curve(to: p(0.82, 0.54), controlPoint1: p(0.81, 0.65), controlPoint2: p(0.83, 0.60))
        heart.curve(to: p(0.50, 0.96), controlPoint1: p(0.96, 0.84), controlPoint2: p(0.75, 0.97))
        heart.curve(to: p(0.20, 0.65), controlPoint1: p(0.25, 0.96), controlPoint2: p(0.08, 0.80))
        heart.curve(to: p(0.52 - sway*0.6, 0.30), controlPoint1: p(0.35, 0.65), controlPoint2: p(0.29, 0.48))
        heart.close()
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.73, blue: 0.08, alpha: 1),
                   ending: NSColor(calibratedRed: 1, green: 0.92, blue: 0.25, alpha: 1))?.draw(in: heart, angle: 90)
        let core = NSBezierPath()
        core.move(to: p(0.50 + sway*0.3, 0.59))
        core.curve(to: p(0.68, 0.84), controlPoint1: p(0.47, 0.72), controlPoint2: p(0.71, 0.73))
        core.curve(to: p(0.33, 0.84), controlPoint1: p(0.64, 0.98), controlPoint2: p(0.34, 0.98))
        core.curve(to: p(0.50 + sway*0.3, 0.59), controlPoint1: p(0.26, 0.73), controlPoint2: p(0.44, 0.73))
        core.close()
        NSColor(calibratedRed: 1, green: 0.98, blue: 0.75, alpha: 1).setFill(); core.fill()
        if strength > 0.55 {
            for index in 0..<2 {
                let cycle = (phase * 0.11 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let opacity = sin(cycle * .pi) * (strength-0.55) * 1.5
                NSColor.systemOrange.withAlphaComponent(opacity).setFill()
                let x = 24 + CGFloat(index)*12 + CGFloat(sin(phase + Double(index)))
                let y = max(9, origin.y + 5 - CGFloat(cycle) * 10)
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 2)).fill()
            }
        }
    }
}
