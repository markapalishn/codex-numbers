import AppKit

class ClickableBadge: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let began = NSEvent.mouseLocation
        let origin = window.frame.origin
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = NSEvent.mouseLocation
            let dx = point.x - began.x, dy = point.y - began.y
            if hypot(dx, dy) > 4 { dragged = true }
            if next.type == .leftMouseUp {
                if !dragged { onClick?() }
                else { window.saveFrame(usingName: "CodexNumbersPanel") }
                break
            }
            if dragged { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
        }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

final class TokenChart: NSView {
    var buckets: [AnalyticsBucket] = [] { didSet { hovered = nil; needsDisplay = true } }
    var hourly = false
    var hovered: Int?
    var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hovered = buckets.isEmpty ? nil : max(0, min(buckets.count-1, Int(x / max(1, bounds.width) * Double(buckets.count))))
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !buckets.isEmpty else { return }
        let maxValue = max(1, buckets.map(\.total).max() ?? 1)
        let top: CGFloat = 29, bottom = bounds.height - 22
        let plotHeight = bottom - top
        let step = bounds.width / CGFloat(buckets.count)
        for level in 0...2 {
            let y = top + plotHeight * CGFloat(level) / 2
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
            let path = NSBezierPath(); path.move(to: NSPoint(x: 0, y: y)); path.line(to: NSPoint(x: bounds.width, y: y)); path.stroke()
        }
        for (index, bucket) in buckets.enumerated() {
            let height = bucket.total == 0 ? 2 : max(3, plotHeight * CGFloat(bucket.total) / CGFloat(maxValue))
            let rect = NSRect(x: CGFloat(index) * step + 1, y: bottom-height, width: max(1, step-3), height: height)
            (bucket.total == 0 ? NSColor.tertiaryLabelColor.withAlphaComponent(0.12) : NSColor.controlAccentColor.withAlphaComponent(hovered == index ? 1 : 0.65)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(3, step/3), yRadius: min(3, step/3)).fill()
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = hourly ? "HH:mm" : "d MMM"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let first = formatter.string(from: buckets.first!.date) as NSString
        first.draw(at: NSPoint(x: 0, y: bottom+7), withAttributes: attributes)
        let last = formatter.string(from: buckets.last!.date) as NSString
        last.draw(at: NSPoint(x: bounds.width-last.size(withAttributes: attributes).width, y: bottom+7), withAttributes: attributes)
        let caption: String
        if let hovered {
            caption = formatter.string(from: buckets[hovered].date) + " · " + Usage.exact(buckets[hovered].total) + " токенов"
        } else { caption = "Динамика расхода" }
        (caption as NSString).draw(at: NSPoint(x: 0, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

final class AnalyticsDocument: NSView { override var isFlipped: Bool { true } }

final class AnalyticsController: NSWindowController {
    var exportView: NSView!
    var samples: [TokenSample] = []
    var period = 1
    var selectedProject: String?
    var selectedModel: String?
    let totalLabel = NSTextField(labelWithString: "—")
    let countLabel = NSTextField(labelWithString: "—")
    let averageLabel = NSTextField(labelWithString: "—")
    let detailLabel = NSTextField(labelWithString: "")
    let chart = TokenChart()
    let rows = NSStackView()
    let filterButton = NSButton(title: "Все проекты и модели", target: nil, action: nil)
    let tabs = NSSegmentedControl(labels: ["Проекты", "Модели", "Запросы"], trackingMode: .selectOne, target: nil, action: nil)
    let periods = NSSegmentedControl(labels: ["Сегодня", "7 дней", "30 дней", "Всё время"], trackingMode: .selectOne, target: nil, action: nil)
    var groupKeys: [String] = []
    var expandedProjects = Set<String>()
    enum RowAction {
        case expand(String)
        case filter(project: String?, model: String?)
    }
    var rowActions: [RowAction] = []
    let scroll = NSScrollView()
    var signature = ""

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Аналитика Codex"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        super.init(window: window)
        let content = NSView(frame: window.contentView!.bounds)
        exportView = content
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.style = .regular; glass.cornerRadius = 20; glass.contentView = content
            window.contentView = glass
        } else {
            let glass = NSVisualEffectView(frame: content.bounds)
            glass.material = .popover; glass.state = .active; glass.addSubview(content)
            content.autoresizingMask = [.width, .height]; window.contentView = glass
        }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 42),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: "Расход токенов")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        stack.addArrangedSubview(heading)
        periods.selectedSegment = period; periods.target = self; periods.action = #selector(changePeriod)
        periods.segmentStyle = .rounded
        stack.addArrangedSubview(periods)
        let metrics = NSStackView(); metrics.orientation = .horizontal; metrics.distribution = .fillEqually; metrics.spacing = 20
        for (label, name) in [(totalLabel, "Всего токенов"), (countLabel, "Запросов"), (averageLabel, "В среднем за запрос")] {
            let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 4
            label.font = .monospacedDigitSystemFont(ofSize: 25, weight: .medium)
            column.addArrangedSubview(label)
            let caption = NSTextField(labelWithString: name); caption.font = .systemFont(ofSize: 11); caption.textColor = .secondaryLabelColor
            column.addArrangedSubview(caption); metrics.addArrangedSubview(column)
        }
        stack.addArrangedSubview(metrics); metrics.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 135).isActive = true
        filterButton.isBordered = false; filterButton.font = .systemFont(ofSize: 11); filterButton.contentTintColor = .secondaryLabelColor
        filterButton.target = self; filterButton.action = #selector(clearFilter)
        stack.addArrangedSubview(filterButton)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        stack.addArrangedSubview(tabs)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 5
        rows.translatesAutoresizingMaskIntoConstraints = false
        let document = AnalyticsDocument(); document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rows); scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ values: [TokenSample]) {
        var hash = Hasher()
        hash.combine(Calendar.current.startOfDay(for: Date()))
        for value in values {
            hash.combine(value.id); hash.combine(value.request); hash.combine(value.projectPath)
            hash.combine(value.model); hash.combine(value.count); hash.combine(value.authoritative); hash.combine(value.requestText)
        }
        let next = String(hash.finalize())
        guard next != signature else { return }
        signature = next; samples = values
        if window?.isVisible == true { rebuild() }
    }
    func present(near badge: NSWindow) {
        rebuild()
        if let screen = badge.screen ?? NSScreen.main, let window {
            let area = screen.visibleFrame
            let x = max(area.minX+12, min(badge.frame.midX-window.frame.width/2, area.maxX-window.frame.width-12))
            let above = badge.frame.maxY+8
            let y = above+window.frame.height <= area.maxY ? above : max(area.minY+12, min(badge.frame.minY-window.frame.height-8, area.maxY-window.frame.height-12))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    @objc func changePeriod() { period = periods.selectedSegment; rebuild() }
    @objc func changeTab() { rebuild() }
    @objc func clearFilter() { selectedProject = nil; selectedModel = nil; rebuild() }
    @objc func selectGroup(_ sender: NSButton) {
        guard rowActions.indices.contains(sender.tag) else { return }
        switch rowActions[sender.tag] {
        case .expand(let project):
            if expandedProjects.contains(project) { expandedProjects.remove(project) } else { expandedProjects.insert(project) }
        case .filter(let project, let model):
            selectedProject = project; selectedModel = model; tabs.selectedSegment = 2
            scroll.contentView.scroll(to: .zero)
        }
        rebuild()
    }
    func register(_ action: RowAction) -> Int { rowActions.append(action); return rowActions.count-1 }
    func rebuild() {
        let position = scroll.contentView.bounds.origin
        defer {
            scroll.documentView?.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        rowActions = []
        let summary = AnalyticsSummary(samples: samples, period: period, project: selectedProject, model: selectedModel)
        totalLabel.stringValue = (summary.isEstimate ? "≈" : "") + Usage.format(summary.total)
        totalLabel.toolTip = Usage.exact(summary.total) + " токенов"
        countLabel.stringValue = "\(summary.requestCount)"
        averageLabel.stringValue = (summary.isEstimate ? "≈" : "") + Usage.format(summary.requestCount == 0 ? 0 : summary.total / summary.requestCount)
        detailLabel.stringValue = "Из кэша: \(summary.cachePercent)% входа   ·   Получено: \(Usage.format(summary.output))"
        chart.hourly = summary.hourly; chart.buckets = summary.buckets()
        let filters = [selectedProject.map { URL(fileURLWithPath: $0).lastPathComponent }, selectedModel].compactMap { $0 }
        filterButton.title = filters.isEmpty ? "Все проекты и модели" : filters.joined(separator: " · ") + "  × Сбросить"
        filterButton.isEnabled = !filters.isEmpty
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        if summary.samples.isEmpty {
            let empty = NSTextField(labelWithString: "За этот период пока нет запросов")
            empty.textColor = .secondaryLabelColor; empty.font = .systemFont(ofSize: 13)
            rows.addArrangedSubview(empty); return
        }
        if tabs.selectedSegment == 2 {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "d MMM, HH:mm"
            for request in summary.requests.prefix(200) {
                let title = request.title
                let subtitle = "\(request.project) · \(formatter.string(from: request.date)) · \(request.models)"
                let excerpt = request.text.count > 4000 ? String(request.text.prefix(4000)) + "…" : request.text
                addRow(title: title, subtitle: subtitle, value: (request.isEstimate ? "≈" : "") + Usage.format(request.total), ratio: nil, actionIndex: nil, tooltip: (excerpt.isEmpty ? "Текст запроса отсутствует в журнале" : excerpt) + "\n\n" + Usage.exact(request.total) + " токенов")
            }
        } else {
            let groups = summary.groups(byModel: tabs.selectedSegment == 1)
            groupKeys = groups.map(\.key)
            for group in groups {
                let share = Double(group.total) / Double(max(1, summary.total))
                let isProject = tabs.selectedSegment == 0
                let expanded = expandedProjects.contains(group.key)
                let action = register(isProject ? .expand(group.key) : .filter(project: selectedProject, model: group.key))
                let title = isProject ? (expanded ? "▾  " : "▸  ") + group.title : group.title
                addRow(title: title, subtitle: "\(group.requests) запр. · \(Int((share*100).rounded()))%", value: (group.isEstimate ? "≈" : "") + Usage.format(group.total), ratio: share, actionIndex: action, tooltip: group.key + " · " + Usage.exact(group.total) + " токенов")
                if isProject && expanded {
                    let projectSummary = AnalyticsSummary(samples: samples, period: period, project: group.key, model: selectedModel)
                    for model in projectSummary.groups(byModel: true) {
                        let modelShare = Double(model.total) / Double(max(1, group.total))
                        let action = register(.filter(project: group.key, model: model.key))
                        addRow(title: model.title, subtitle: "\(model.requests) запр. · \(Int((modelShare*100).rounded()))% проекта", value: (model.isEstimate ? "≈" : "") + Usage.format(model.total), ratio: modelShare, actionIndex: action, tooltip: Usage.exact(model.total) + " токенов · Показать запросы", indent: 22)
                    }
                    let action = register(.filter(project: group.key, model: nil))
                    addRow(title: "Все запросы проекта", subtitle: "", value: "", ratio: nil, actionIndex: action, indent: 22)
                }
            }
        }
    }
    func addRow(title: String, subtitle: String, value: String, ratio: Double?, actionIndex: Int?, tooltip: String? = nil, indent: CGFloat = 0) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        row.toolTip = tooltip
        let titleLabel = NSTextField(labelWithString: title); titleLabel.font = .systemFont(ofSize: 12, weight: .medium); titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = NSTextField(labelWithString: subtitle); subtitleLabel.font = .systemFont(ofSize: 10); subtitleLabel.textColor = .secondaryLabelColor; subtitleLabel.lineBreakMode = .byTruncatingTail
        let valueLabel = NSTextField(labelWithString: value); valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.toolTip = tooltip
        subtitleLabel.toolTip = tooltip
        for label in [titleLabel, subtitleLabel, valueLabel] { label.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(label) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2 + indent), titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8), valueLabel.topAnchor.constraint(equalTo: titleLabel.topAnchor)
        ])
        if let ratio {
            let bar = NSView(); bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor; bar.layer?.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(bar)
            NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2 + indent), bar.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3), bar.heightAnchor.constraint(equalToConstant: 3), bar.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: max(0.001, ratio), constant: -(indent+8)*max(0.001, ratio))])
        }
        if let actionIndex {
            let button = NSButton(title: "", target: self, action: #selector(selectGroup(_:)))
            button.isBordered = false; button.tag = actionIndex; button.toolTip = tooltip
            let hint: String
            if case .expand = rowActions[actionIndex] { hint = "Развернуть или свернуть модели" } else { hint = "Показать запросы" }
            button.setAccessibilityLabel("\(title), \(value) токенов. \(hint)")
            button.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(button)
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: row.leadingAnchor), button.trailingAnchor.constraint(equalTo: row.trailingAnchor), button.topAnchor.constraint(equalTo: row.topAnchor), button.bottomAnchor.constraint(equalTo: row.bottomAnchor)])
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        row.heightAnchor.constraint(equalToConstant: ratio == nil ? 43 : 50).isActive = true
    }
}
