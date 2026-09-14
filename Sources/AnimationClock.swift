import AppKit
import QuartzCore

/// One clock for the badge's flame, counters, resize and limit transition.
/// A weak target breaks the run loop → display link → owner retain cycle.
final class AnimationClock: NSObject {
    private final class Target: NSObject {
        weak var owner: AnimationClock?
        @objc func tick(_ sender: Any) { owner?.tick() }
    }
    private weak var view: NSView?
    private let target = Target()
    private var link: AnyObject?
    private var fallback: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var active = false
    private var lastFrame: TimeInterval = 0
    private var reduceMotion = false
    private(set) var economical = false
    var onFrame: ((TimeInterval, TimeInterval) -> Void)?
    var onEnvironmentChange: (() -> Void)?
    var isVisible: Bool {
        !sleeping && view?.window?.isVisible == true &&
        view?.window?.occlusionState.contains(.visible) == true &&
        view?.isHiddenOrHasHiddenAncestor == false
    }
    var canAnimate: Bool { isVisible && !reduceMotion }
    var isRunning: Bool {
        if #available(macOS 14.0, *) { return (link as? CADisplayLink).map { !$0.isPaused } ?? false }
        return fallback != nil
    }
    private func updatePreferences() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        economical = ProcessInfo.processInfo.isLowPowerModeEnabled ||
            ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    }
    init(view: NSView) {
        self.view = view
        super.init()
        target.owner = self
        updatePreferences()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.sleeping = true }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.sleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.sleeping = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.sleeping = false }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
        observe(.default, .NSProcessInfoPowerStateDidChange)
        observe(.default, ProcessInfo.thermalStateDidChangeNotification)
        observe(.default, NSWindow.didChangeOcclusionStateNotification)
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: (() -> Void)? = nil) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            if let window = notification.object as? NSWindow, window !== self.view?.window { return }
            action?()
            self.updatePreferences()
            self.onEnvironmentChange?()
            self.setActive(self.active)
        }
        observers.append((center, observer))
    }
    func setActive(_ requested: Bool) {
        active = requested
        guard requested && canAnimate, let view else {
            if #available(macOS 14.0, *) { (link as? CADisplayLink)?.isPaused = true }
            fallback?.invalidate(); fallback = nil; lastFrame = 0
            return
        }
        let rate: Float = economical ? 30 : 60
        if #available(macOS 14.0, *) {
            let display: CADisplayLink
            if let existing = link as? CADisplayLink { display = existing }
            else {
                display = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
                link = display
                display.add(to: .main, forMode: .common)
            }
            if display.preferredFrameRateRange.preferred != rate {
                display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: rate, preferred: rate)
            }
            display.isPaused = false
        } else if fallback == nil || abs(fallback!.timeInterval - 1 / Double(rate)) > 0.001 {
            fallback?.invalidate()
            let timer = Timer(timeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.002
            fallback = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func tick() {
        guard canAnimate else { onEnvironmentChange?(); setActive(active); return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastFrame == 0 ? 0 : min(1 / 15.0, max(0, now - lastFrame))
        lastFrame = now
        onFrame?(now, elapsed)
    }
    deinit {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        fallback?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}

extension NSView {
    /// Core Animation composites the transition; Swift does no per-frame layout.
    func animateContentChange() {
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else {
            layer?.removeAnimation(forKey: "contentChange")
            return
        }
        wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(transition, forKey: "contentChange")
    }
}
