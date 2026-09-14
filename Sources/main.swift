import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var panel: NSPanel!
    var badge: BadgeView!
    var timer: Timer?
    var countMode = TokenCountMode.load()
    var current: Usage?
    var displayed: Usage?
    let queue = DispatchQueue(label: "local.codex-numbers.reader", qos: .utility)
    let monitor = UsageMonitor(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex").appendingPathComponent("sessions"))
    var polling = false
    var analytics: AnalyticsController!
    var previewExported = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "—"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.toolTip = "Использование лимита Codex"
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 172, height: 72), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        let content = BadgeView(frame: NSRect(origin: .zero, size: glassFrame.size))
        badge = content
        content.onClick = { [weak self] in self?.toggleAnalytics() }
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.button)
        content.setAccessibilityLabel("Показать или скрыть аналитику расхода Codex")
        content.toolTip = "Нажмите, чтобы показать или скрыть аналитику · потяните, чтобы переместить"
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.style = .regular
            glass.cornerRadius = 30
            glass.autoresizingMask = [.width, .height]
            glass.contentView = content
            surface.addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: glassFrame)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 30
            glass.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            glass.addSubview(content)
            surface.addSubview(glass)
        }
        if !panel.setFrameUsingName("CodexNumbersPanel") {
            if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX-590, y: screen.visibleFrame.minY+24)) }
        }
        panel.setContentSize(NSSize(width: 172, height: 72))
        panel.orderFrontRegardless()
        analytics = AnalyticsController()
        analytics.countMode = countMode
        analytics.onCountModeChange = { [weak self] mode in self?.setCountMode(mode) }
        updateMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.3
    }
    func refresh() {
        guard !polling else { return }
        polling = true
        queue.async { [self] in
            let usage = monitor.poll()
            let snapshot = AnalyticsSnapshot(samples: monitor.polledSamples)
            DispatchQueue.main.async { [self] in
                polling = false
                analytics.update(snapshot)
                if let flag = CommandLine.arguments.firstIndex(of: "--preview"),
                   CommandLine.arguments.indices.contains(flag + 1), !previewExported {
                    previewExported = true
                    analytics.present(near: panel)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        guard let view = analytics.exportView else { NSApp.terminate(nil); return }
                        view.wantsLayer = true
                        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                        let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                        func capture(_ url: URL) {
                            view.layoutSubtreeIfNeeded()
                            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
                            }
                        }
                        capture(output)
                        if !analytics.rowActions.isEmpty {
                            let project = NSButton(); project.tag = 0
                            analytics.selectGroup(project)
                            capture(output.deletingPathExtension().appendingPathExtension("projects-expanded.png"))
                        }
                        badge.wantsLayer = true
                        badge.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                        badge.layer?.cornerRadius = 30
                        func captureBadge(_ name: String) {
                            if let bitmap = badge.bitmapImageRepForCachingDisplay(in: badge.bounds) {
                                badge.cacheDisplay(in: badge.bounds, to: bitmap)
                                if let png = bitmap.representation(using: .png, properties: [:]) {
                                    try? png.write(to: output.deletingPathExtension().appendingPathExtension(name + ".png"))
                                }
                            }
                        }
                        captureBadge("badge")
                        for (name, count) in [("idle", 0), ("low", 10_000), ("high", 1_000_000)] {
                            var example = Usage()
                            example.tokens = Tokens(["input_tokens": count])
                            example.running = count > 0
                            example.remainingLimit = 86
                            badge.usage = example
                            badge.requestVisibility = example.running ? 1 : 0
                            fitPanel(for: [example])
                            captureBadge("badge-" + name)
                        }
                        var parallelExample = Usage()
                        parallelExample.running = true
                        parallelExample.activeRequestIDs = ["preview-one", "preview-two"]
                        parallelExample.tokens = Tokens(["input_tokens": 300_000, "output_tokens": 15_000])
                        parallelExample.remainingLimit = 86
                        for mode in TokenCountMode.allCases {
                            parallelExample.countMode = mode
                            badge.usage = parallelExample; badge.requestVisibility = 1
                            fitPanel(for: [parallelExample])
                            captureBadge("badge-parallel-" + mode.rawValue)
                        }
                        analytics.tabs.selectedSegment = 1
                        analytics.rebuild()
                        capture(output.deletingPathExtension().appendingPathExtension("models.png"))
                        if !analytics.groupKeys.isEmpty {
                            let selected = NSButton(); selected.tag = 0
                            analytics.selectGroup(selected)
                            capture(output.deletingPathExtension().appendingPathExtension("requests.png"))
                        }
                        NSApp.terminate(nil)
                    }
                }
                var usage = usage ?? Usage()
                usage.countMode = countMode
                current = usage
                animateNumbers(to: usage.badgeUsage)
            }
        }
    }
    func renderNumbers(_ usage: Usage) {
        displayed = usage
        badge.usage = usage
        let used = usage.remainingLimit.map { "\(100 - $0)%" } ?? "—"
        if item.button?.title != used {
            item.button?.title = used
            item.button?.toolTip = "Использовано лимита Codex: \(used)"
        }
    }
    func fitPanel(for usages: [Usage]) {
        setPanelWidth(usages.map { BadgeView.preferredWidth(for: $0) + 12 }.max() ?? 172)
    }
    func setPanelWidth(_ width: CGFloat) {
        var frame = panel.frame
        let right = frame.maxX
        let scale = panel.backingScaleFactor
        frame.size.width = (width * scale).rounded() / scale
        frame.origin.x = right - frame.width
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX-frame.width))
        }
        guard panel.frame != frame else { return }
        // Coalesce layout and drawing with the next display refresh.
        panel.setFrame(frame, display: false)
    }
    func animateNumbers(to target: Usage) {
        badge.numberFrame = nil
        let targetWidth = BadgeView.preferredWidth(for: target) + 12
        let targetVisibility: CGFloat = target.running ? 1 : 0
        guard let start = displayed,
              start.activeRequestIDs == target.activeRequestIDs || !start.running || !target.running,
              badge.canAnimate,
              start.requestTokens != target.requestTokens || start.remainingLimit != target.remainingLimit ||
              start.running != target.running || abs(panel.frame.width-targetWidth) > 0.5 else {
            badge.requestVisibility = targetVisibility
            renderNumbers(target)
            setPanelWidth(targetWidth)
            return
        }
        let startWidth = panel.frame.width
        let startVisibility = badge.requestVisibility
        let began = ProcessInfo.processInfo.systemUptime
        badge.numberFrame = { [weak self] now, finish in
            guard let self else { return false }
            let progress = finish ? 1 : min(1, (now - began) / 0.55)
            let eased = 1 - pow(1 - progress, 3)
            func interpolate(_ a: Int, _ b: Int) -> Int {
                Int((Double(a) + (Double(b) - Double(a)) * eased).rounded())
            }
            var frame = target
            frame.tokens.input = interpolate(start.tokens.input, target.tokens.input)
            frame.tokens.cached = interpolate(start.tokens.cached, target.tokens.cached)
            frame.tokens.output = interpolate(start.tokens.output, target.tokens.output)
            if let a = start.remainingLimit, let b = target.remainingLimit { frame.remainingLimit = interpolate(a, b) }
            self.badge.requestVisibility = startVisibility + (targetVisibility-startVisibility) * CGFloat(eased)
            self.setPanelWidth(startWidth + (targetWidth-startWidth) * CGFloat(eased))
            self.renderNumbers(frame)
            if progress >= 1 {
                self.badge.requestVisibility = targetVisibility
                self.renderNumbers(target)
                self.setPanelWidth(targetWidth)
                self.panel.saveFrame(usingName: "CodexNumbersPanel")
            }
            return progress < 1
        }
    }
    func updateMenu() {
        let menu = NSMenu()
        let details = menu.addItem(withTitle: "Аналитика", action: #selector(showAnalytics), keyEquivalent: "")
        details.target = self
        menu.addItem(.separator())
        let modeMenu = NSMenu()
        for (index, mode) in TokenCountMode.allCases.enumerated() {
            let entry = modeMenu.addItem(withTitle: mode.title, action: #selector(changeCountMode(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = index; entry.state = mode == countMode ? .on : .off
        }
        let modeItem = menu.addItem(withTitle: "Подсчёт токенов", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Завершить Codex Numbers", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        badge.menu = menu
        item.menu = menu.copy() as? NSMenu
    }
    func setCountMode(_ mode: TokenCountMode) {
        guard countMode != mode else { return }
        countMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: TokenCountMode.defaultsKey)
        if analytics.countMode != mode { analytics.countMode = mode }
        badge.numberFrame = nil
        if var usage = current {
            usage.countMode = mode; current = usage
            let target = usage.badgeUsage
            badge.requestVisibility = target.running ? 1 : 0
            renderNumbers(target); fitPanel(for: [target]); badge.animateContentChange()
        }
        updateMenu()
    }
    @objc func changeCountMode(_ sender: NSMenuItem) {
        guard TokenCountMode.allCases.indices.contains(sender.tag) else { return }
        setCountMode(TokenCountMode.allCases[sender.tag])
    }
    @objc func showAnalytics() { analytics.present(near: panel) }
    func toggleAnalytics() {
        if analytics.window?.isVisible == true {
            analytics.close()
        } else {
            showAnalytics()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return true
    }
    @objc func quitApp() { panel.saveFrame(usingName: "CodexNumbersPanel"); NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--snapshot") {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex").appendingPathComponent("sessions")
    var usage = UsageMonitor(root: root).poll()
    usage?.countMode = TokenCountMode.load()
    print(usage?.line ?? "Нет данных")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
