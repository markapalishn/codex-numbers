import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var panel: NSPanel!
    var label: NSTextField!
    var timer: Timer?
    var current: Usage?
    var displayed: Usage?
    var numberAnimation: Timer?
    let queue = DispatchQueue(label: "local.codex-numbers.reader", qos: .utility)
    let monitor = UsageMonitor(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex").appendingPathComponent("sessions"))
    var polling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◈ —"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let surface = NSView(frame: panel.contentView!.bounds)
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        let glassFrame = surface.bounds.insetBy(dx: 6, dy: 6)
        let content = NSView(frame: NSRect(origin: .zero, size: glassFrame.size))
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.style = .regular
            glass.cornerRadius = 20
            glass.autoresizingMask = [.width, .height]
            glass.contentView = content
            surface.addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: glassFrame)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 20
            glass.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            glass.addSubview(content)
            surface.addSubview(glass)
        }
        label = NSTextField(labelWithString: "Codex · ожидание данных…")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        if !panel.setFrameUsingName("CodexNumbersPanel") {
            if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-590, y: screen.visibleFrame.minY+24)) }
        }
        panel.setContentSize(NSSize(width: panel.frame.width, height: 52))
        if !UserDefaults.standard.bool(forKey: "panelHidden") { panel.orderFrontRegardless() }
        updateMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        guard !polling else { return }
        polling = true
        queue.async { [self] in
            let usage = monitor.poll()
            DispatchQueue.main.async { [self] in
                polling = false
                guard let usage else { return }
                current = usage
                animateNumbers(to: usage)
                item.button?.toolTip = usage.line + "\n" + usage.project
                updateMenu()
                panel.saveFrame(usingName: "CodexNumbersPanel")
            }
        }
    }
    func renderNumbers(_ usage: Usage) {
        displayed = usage
        label.stringValue = (usage.running ? "↻ " : "") + usage.line
        item.button?.title = "◈ " + Usage.format(usage.tokens.input) + (usage.running ? " ↻" : "")
    }
    func fitPanel(for usages: [Usage]) {
        let font = label.font ?? NSFont.systemFont(ofSize: 12)
        let width = usages.map {
            ((($0.running ? "↻ " : "") + $0.line) as NSString).size(withAttributes: [.font: font]).width + 48
        }.max() ?? 450
        var frame = panel.frame
        frame.size.width = max(450, ceil(width))
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX-frame.width))
        }
        panel.setFrame(frame, display: true)
    }
    func animateNumbers(to target: Usage) {
        numberAnimation?.invalidate()
        numberAnimation = nil
        guard let start = displayed,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              start.tokens != target.tokens || start.context != target.context else {
            renderNumbers(target)
            fitPanel(for: [target])
            return
        }
        // Reserve the larger endpoint width so the window stays still during counting.
        fitPanel(for: [start, target])
        let began = ProcessInfo.processInfo.systemUptime
        let animation = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.55)
            let eased = 1 - pow(1 - progress, 3)
            func interpolate(_ a: Int, _ b: Int) -> Int {
                Int((Double(a) + (Double(b) - Double(a)) * eased).rounded())
            }
            var frame = target
            frame.tokens.input = interpolate(start.tokens.input, target.tokens.input)
            frame.tokens.cached = interpolate(start.tokens.cached, target.tokens.cached)
            frame.tokens.output = interpolate(start.tokens.output, target.tokens.output)
            if let a = start.context, let b = target.context { frame.context = interpolate(a, b) }
            self.renderNumbers(frame)
            if progress >= 1 {
                timer.invalidate()
                self.numberAnimation = nil
                self.renderNumbers(target)
                self.fitPanel(for: [target])
                self.panel.saveFrame(usingName: "CodexNumbersPanel")
            }
        }
        numberAnimation = animation
        RunLoop.main.add(animation, forMode: .common)
    }
    func updateMenu() {
        let menu = NSMenu()
        func info(_ title: String) { let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.isEnabled = false; menu.addItem(entry) }
        info(current.map { "\($0.project) · \($0.running ? "в работе" : "последний запрос")" } ?? "Ожидание Codex")
        if let u = current {
            info(u.line)
        }
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: panel.isVisible ? "Скрыть индикатор" : "Показать индикатор", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        let reset = menu.addItem(withTitle: "Вернуть индикатор на экран", action: #selector(resetPanel), keyEquivalent: ""); reset.target = self
        let quit = menu.addItem(withTitle: "Завершить Codex Numbers", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        item.menu = menu
    }
    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        UserDefaults.standard.set(!panel.isVisible, forKey: "panelHidden"); updateMenu()
    }
    @objc func resetPanel() {
        if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-panel.frame.width-20, y: screen.visibleFrame.minY+24)) }
        panel.orderFrontRegardless(); UserDefaults.standard.set(false, forKey: "panelHidden"); updateMenu()
    }
    @objc func quitApp() { panel.saveFrame(usingName: "CodexNumbersPanel"); NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--snapshot") {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex").appendingPathComponent("sessions")
    print(UsageMonitor(root: root).poll()?.line ?? "Нет данных")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
