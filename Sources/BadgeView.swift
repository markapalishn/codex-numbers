import AppKit

final class BadgeView: ClickableBadge {
    var usage: Usage? {
        didSet {
            updateLimitLayout()
            if oldValue?.requestTokens != usage?.requestTokens || oldValue?.requestCaption != usage?.requestCaption || oldValue?.isEstimate != usage?.isEstimate {
                setNeedsDisplay(NSRect(x: 0, y: 0, width: max(0, bounds.width - limitWidth), height: bounds.height))
            }
            if oldValue?.remainingLimit != usage?.remainingLimit || oldValue?.limitResetAt != usage?.limitResetAt || oldValue?.limitWindowDuration != usage?.limitWindowDuration {
                invalidateLimit()
            }
            if oldValue?.requestTokens != usage?.requestTokens || oldValue?.isEstimate != usage?.isEstimate {
                countText = usage.map { ($0.isEstimate ? "≈" : "") + Usage.format($0.requestTokens) } ?? "—"
                countShowsUnit = (usage?.requestTokens ?? 0) < 1000
                let availableWidth = Self.requestNumberWidth - (countShowsUnit ? Self.unitGap + Self.unitWidth : 0)
                countFont = Self.fittedNumberFont(for: countText, width: availableWidth)
                countWidth = (countText as NSString).size(withAttributes: [.font: countFont]).width
            }
            updateLimitRotation()
            updateAnimation()
            updateAccessibilityLabel()
        }
    }
    var requestVisibility: CGFloat = 0 { didSet { if oldValue != requestVisibility { needsDisplay = true; updateAnimation() } } }
    /// Returns true while the finite counter/resize transition is still running.
    var numberFrame: ((TimeInterval, Bool) -> Bool)? { didSet { updateAnimation() } }
    var canAnimate: Bool { clock.canAnimate }
    // Only lifecycle changes select a different width; content never resizes the badge.
    private static let contentPadding: CGFloat = 16
    private static let requestTextX: CGFloat = 57
    private static let captionAdjustment: CGFloat = 1
    private static let unitGap: CGFloat = 6
    private static let unitText = "тк"
    private static let unitFont = NSFont.systemFont(ofSize: 10)
    private static let unitWidth = (unitText as NSString).size(withAttributes: [.font: unitFont]).width
    private static let limitCaptionFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let collapsedWidth: CGFloat = 144
    static let expandedWidth: CGFloat = 328
    private let limitWidth = collapsedWidth
    private static let ringInset = contentPadding + 1.25
    private static let limitNumberWidth = collapsedWidth - ringInset - 27 - contentPadding
    private static let requestNumberWidth = expandedWidth - collapsedWidth - requestTextX - contentPadding
    private var measuredResetDays: Int?
    private var resetNumberFont = numberFont
    private var limitRotationTimer: Timer?
    private var showsReset = false
    private var transitionToReset = false
    private var limitTransitionProgress: CGFloat?
    private var limitTransitionStart: TimeInterval?
    private var phase: Double = 0
    private var accessibilityText = ""
    private var countText = "—"
    private var countShowsUnit = true
    private var countWidth: CGFloat = 0
    private var countFont = numberFont
    private var gradientMix: CGFloat = -1
    private var flameGradient: NSGradient?
    private var heartGradient: NSGradient?
    private lazy var clock: AnimationClock = {
        let clock = AnimationClock(view: self)
        clock.onFrame = { [weak self] now, elapsed in self?.advance(now: now, elapsed: elapsed) }
        clock.onEnvironmentChange = { [weak self] in self?.environmentChanged() }
        return clock
    }()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        environmentChanged()
    }
    private func invalidateLimit() {
        setNeedsDisplay(NSRect(x: max(0, bounds.width - limitWidth), y: 0, width: limitWidth, height: bounds.height))
    }
    private func environmentChanged() {
        if !canAnimate {
            _ = numberFrame?(ProcessInfo.processInfo.systemUptime, true)
            numberFrame = nil
            finishLimitTransition()
        }
        updateLimitRotation()
        updateAnimation()
        needsDisplay = true
    }
    private func updateAnimation() {
        clock.setActive(numberFrame != nil || limitTransitionStart != nil || (intensity > 0 && requestVisibility > 0))
    }
    private func advance(now: TimeInterval, elapsed: TimeInterval) {
        if let frame = numberFrame, !frame(now, false) { numberFrame = nil }
        if let began = limitTransitionStart {
            let progress = min(1, (now - began) / 0.48)
            limitTransitionProgress = CGFloat(1 - pow(1 - progress, 3))
            invalidateLimit()
            if progress >= 1 { finishLimitTransition() }
        }
        if intensity > 0 && requestVisibility > 0 {
            phase += elapsed * (3 + intensity * 4.5)
            setNeedsDisplay(NSRect(x: 12, y: 5, width: 39, height: 49))
        }
        updateAnimation()
    }
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
    private func updateLimitRotation() {
        guard usage?.limitResetAt != nil, clock.isVisible else {
            limitRotationTimer?.invalidate(); limitRotationTimer = nil
            if usage?.limitResetAt == nil {
                limitTransitionStart = nil; limitTransitionProgress = nil; showsReset = false
            }
            return
        }
        guard limitRotationTimer == nil else { return }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.animateLimitTransition() }
        timer.tolerance = 0.4
        limitRotationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func animateLimitTransition() {
        transitionToReset = !showsReset
        limitTransitionStart = ProcessInfo.processInfo.systemUptime
        if !canAnimate { finishLimitTransition(); return }
        limitTransitionProgress = 0
        updateAnimation()
    }
    private func finishLimitTransition() {
        guard limitTransitionStart != nil else { return }
        showsReset = transitionToReset
        limitTransitionStart = nil; limitTransitionProgress = nil
        invalidateLimit()
        updateAccessibilityLabel()
    }
    private static func resetDays(for usage: Usage?, now: Date = Date()) -> Int? {
        guard let reset = usage?.limitResetAt else { return nil }
        return max(0, Int(ceil((reset - now.timeIntervalSince1970) / 86_400)))
    }
    private func resetDays() -> Int? { Self.resetDays(for: usage) }
    private static func resetDaysText(_ days: Int) -> String {
        let lastTwo = days % 100
        let ending = (11...14).contains(lastTwo) ? "дней" : (days % 10 == 1 ? "день" : ((2...4).contains(days % 10) ? "дня" : "дней"))
        return "\(days) \(ending)"
    }
    private static func fittedNumberFont(for text: String, width: CGFloat) -> NSFont {
        var font = numberFont
        var measured = (text as NSString).size(withAttributes: [.font: font]).width
        // System fonts may use different optical metrics at smaller sizes.
        // Measure the resulting font as well, rather than assuming linear scaling.
        while measured > width {
            let size = floor(font.pointSize * width / measured * 10) / 10
            guard size > 0, size < font.pointSize else { break }
            font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            measured = (text as NSString).size(withAttributes: [.font: font]).width
        }
        return font
    }
    private func updateLimitLayout() {
        let days = resetDays()
        guard measuredResetDays != days else { return }
        measuredResetDays = days
        resetNumberFont = Self.fittedNumberFont(for: days.map { Self.resetDaysText($0) } ?? "—", width: Self.limitNumberWidth)
        invalidateLimit()
    }
    private func updateAccessibilityLabel() {
        let count = (usage?.isEstimate == true ? "≈" : "") + Usage.exact(usage?.requestTokens ?? 0)
        let used = usage?.remainingLimit.map { "\(100 - $0)%" } ?? "—"
        let request = usage?.running == true ? "\(usage!.requestCaption): \(count) токенов. " : ""
        let limit = showsReset && resetDays() != nil
            ? "До сброса лимита: \(Self.resetDaysText(resetDays()!)). "
            : "Использовано лимита: \(used). "
        let label = request + limit + "Открыть аналитику"
        if label != accessibilityText { accessibilityText = label; setAccessibilityLabel(label) }
    }
    deinit { limitRotationTimer?.invalidate() }
    override var isFlipped: Bool { true }
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
    static func preferredWidth(for usage: Usage) -> CGFloat {
        usage.running ? expandedWidth : collapsedWidth
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func text(_ value: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        let small = Self.limitCaptionFont
        let dividerX = bounds.width - limitWidth
        if requestVisibility > 0, dividerX > 12, needsToDraw(NSRect(x: 0, y: 0, width: dividerX, height: bounds.height)) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: max(0, dividerX-12), height: bounds.height)).addClip()
            NSGraphicsContext.current?.cgContext.setAlpha(requestVisibility)
            if needsToDraw(NSRect(x: 12, y: 5, width: 39, height: 49)) { drawFlame() }
            if needsToDraw(NSRect(x: Self.requestTextX - 2, y: 0, width: max(0, dividerX - Self.requestTextX + 2), height: bounds.height)) {
                text(usage?.requestCaption ?? "Запрос", x: Self.requestTextX + Self.captionAdjustment, y: 10, font: small, color: .secondaryLabelColor)
                let count = countText
                text(count, x: Self.requestTextX, y: 25 + Self.numberFont.ascender - countFont.ascender, font: countFont, color: .labelColor)
                let numberWidth = countWidth
                if countShowsUnit {
                    text(Self.unitText, x: Self.requestTextX + numberWidth + Self.unitGap, y: 32, font: Self.unitFont, color: .secondaryLabelColor)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard needsToDraw(NSRect(x: dividerX, y: 0, width: limitWidth, height: bounds.height)) else { return }
        if requestVisibility > 0 {
            NSColor.separatorColor.withAlphaComponent(0.45 * requestVisibility).setFill()
            NSBezierPath(roundedRect: NSRect(x: dividerX, y: 17, width: 1, height: 26), xRadius: 0.5, yRadius: 0.5).fill()
        }
        let ringX = dividerX + Self.ringInset
        let ring = NSBezierPath(ovalIn: NSRect(x: ringX, y: 22, width: 16, height: 16))
        ring.lineWidth = 2.5
        NSColor.tertiaryLabelColor.withAlphaComponent(0.2).setStroke(); ring.stroke()
        let remaining = usage?.remainingLimit
        let used = remaining.map { 100 - $0 }
        let limitColor: NSColor = remaining.map { $0 <= 10 ? .systemRed : ($0 <= 25 ? .systemOrange : .systemTeal) } ?? .secondaryLabelColor
        func drawIcon(reset: Bool, alpha: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            if reset, let resetAt = usage?.limitResetAt,
               let duration = usage?.limitWindowDuration, duration > 0 {
                let remainingTime = max(0, min(duration, resetAt - Date().timeIntervalSince1970))
                let elapsed = 1 - remainingTime / duration
                if elapsed > 0 {
                    let arc = NSBezierPath()
                    arc.lineWidth = 2.5; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: NSPoint(x: ringX+8, y: 30), radius: 8,
                        startAngle: -90, endAngle: -90 + 360 * CGFloat(elapsed), clockwise: false)
                    NSColor.systemTeal.setStroke(); arc.stroke()
                }
            } else if let used, used > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 2.5; arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: ringX+8, y: 30), radius: 8, startAngle: -90, endAngle: -90 + 360 * CGFloat(used)/100, clockwise: false)
                limitColor.setStroke(); arc.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let progress = limitTransitionProgress {
            drawIcon(reset: showsReset, alpha: 1 - progress)
            drawIcon(reset: transitionToReset, alpha: progress)
        } else {
            drawIcon(reset: showsReset, alpha: 1)
        }
        func drawLimitText(reset: Bool, offset: CGFloat, alpha: CGFloat) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            if reset, let days = resetDays() {
                text("До сброса", x: ringX + 28, y: 10 + offset, font: small, color: .secondaryLabelColor)
                text(Self.resetDaysText(days), x: ringX + 27, y: 25 + offset + Self.numberFont.ascender - resetNumberFont.ascender, font: resetNumberFont, color: .labelColor)
            } else {
                text("Использовано", x: ringX + 28, y: 10 + offset, font: small, color: .secondaryLabelColor)
                text(used.map { "\($0)%" } ?? "—", x: ringX + 27, y: 25 + offset, font: Self.numberFont, color: .labelColor)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: ringX + 24, y: 5, width: bounds.maxX - ringX - 24, height: bounds.height - 10)).addClip()
        if let progress = limitTransitionProgress {
            let distance: CGFloat = 44
            drawLimitText(reset: showsReset, offset: distance * progress, alpha: 1 - progress)
            drawLimitText(reset: transitionToReset, offset: -distance * (1 - progress), alpha: progress)
        } else {
            drawLimitText(reset: showsReset, offset: 0, alpha: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawFlame() {
        let strength = intensity
        guard strength > 0 else {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 29, width: 10, height: 2), xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        let blueMix = CGFloat(max(0, min(1, (Double(usage?.requestTokens ?? 0) - 800_000) / 200_000)))
        func heatColor(_ warm: NSColor, _ blue: NSColor) -> NSColor {
            warm.blended(withFraction: blueMix, of: blue) ?? warm
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
        if gradientMix != blueMix {
            gradientMix = blueMix
            flameGradient = NSGradient(starting: heatColor(NSColor(calibratedRed: 1, green: 0.24, blue: 0.08, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.32, blue: 1, alpha: 1)),
                ending: heatColor(NSColor(calibratedRed: 1, green: 0.58, blue: 0.07, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.68, blue: 1, alpha: 1)))
            heartGradient = NSGradient(starting: heatColor(NSColor(calibratedRed: 1, green: 0.73, blue: 0.08, alpha: 1), .cyan),
                ending: heatColor(NSColor(calibratedRed: 1, green: 0.92, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.65, green: 0.94, blue: 1, alpha: 1)))
        }
        flameGradient?.draw(in: flame, angle: 90)
        let heart = NSBezierPath()
        heart.move(to: p(0.52 - sway*0.6, 0.30))
        heart.curve(to: p(0.75, 0.66), controlPoint1: p(0.46, 0.48), controlPoint2: p(0.76, 0.47))
        heart.curve(to: p(0.82, 0.54), controlPoint1: p(0.81, 0.65), controlPoint2: p(0.83, 0.60))
        heart.curve(to: p(0.50, 0.96), controlPoint1: p(0.96, 0.84), controlPoint2: p(0.75, 0.97))
        heart.curve(to: p(0.20, 0.65), controlPoint1: p(0.25, 0.96), controlPoint2: p(0.08, 0.80))
        heart.curve(to: p(0.52 - sway*0.6, 0.30), controlPoint1: p(0.35, 0.65), controlPoint2: p(0.29, 0.48))
        heart.close()
        heartGradient?.draw(in: heart, angle: 90)
        let core = NSBezierPath()
        core.move(to: p(0.50 + sway*0.3, 0.59))
        core.curve(to: p(0.68, 0.84), controlPoint1: p(0.47, 0.72), controlPoint2: p(0.71, 0.73))
        core.curve(to: p(0.33, 0.84), controlPoint1: p(0.64, 0.98), controlPoint2: p(0.34, 0.98))
        core.curve(to: p(0.50 + sway*0.3, 0.59), controlPoint1: p(0.26, 0.73), controlPoint2: p(0.44, 0.73))
        core.close()
        heatColor(NSColor(calibratedRed: 1, green: 0.98, blue: 0.75, alpha: 1), .white).setFill(); core.fill()
        if strength > 0.55 {
            for index in 0..<2 {
                let cycle = (phase * 0.11 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let opacity = sin(cycle * .pi) * (strength-0.55) * 1.5
                heatColor(.systemOrange, .cyan).withAlphaComponent(opacity).setFill()
                let x = 24 + CGFloat(index)*12 + CGFloat(sin(phase + Double(index)))
                let y = max(9, origin.y + 5 - CGFloat(cycle) * 10)
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 2)).fill()
            }
        }
    }
}
