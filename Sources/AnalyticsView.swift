import AppKit

class ClickableBadge: NSView {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    private var dragStart = NSPoint.zero
    private var windowOrigin = NSPoint.zero
    private var dragged = false
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = NSEvent.mouseLocation
        windowOrigin = window.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        let dx = point.x - dragStart.x, dy = point.y - dragStart.y
        if hypot(dx, dy) > 4 { dragged = true }
        if dragged { window?.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { window?.saveFrame(usingName: "CodexNumbersPanel") }
        else { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

final class TokenChart: NSView {
    var buckets: [AnalyticsBucket] = [] {
        didSet {
            guard oldValue != buckets else { return }
            if let hovered, !buckets.indices.contains(hovered) { self.hovered = nil }
            maxValue = max(1, buckets.map(\.total).max() ?? 1)
            updateDateLabels()
            needsDisplay = true
        }
    }
    var hourly = false { didSet { if oldValue != hourly { updateDateLabels(); needsDisplay = true } } }
    private var maxValue = 1
    private var dateLabels: [String] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); return formatter
    }()
    private func updateDateLabels() {
        formatter.dateFormat = hourly ? "HH:mm" : "d MMM"
        dateLabels = buckets.map { formatter.string(from: $0.date) }
    }
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
        setHovered(buckets.isEmpty ? nil : max(0, min(buckets.count-1, Int(x / max(1, bounds.width) * Double(buckets.count)))))
    }
    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        let old = hovered
        hovered = index
        setNeedsDisplay(NSRect(x: 0, y: 0, width: bounds.width, height: 25))
        guard !buckets.isEmpty else { return }
        let step = bounds.width / CGFloat(buckets.count)
        for item in [old, index].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: CGFloat(item) * step, y: 27, width: step, height: max(0, bounds.height - 49)))
        }
    }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !buckets.isEmpty else { return }
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
            guard needsToDraw(rect) else { continue }
            (bucket.total == 0 ? NSColor.tertiaryLabelColor.withAlphaComponent(0.12) : NSColor.controlAccentColor.withAlphaComponent(hovered == index ? 1 : 0.65)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(3, step/3), yRadius: min(3, step/3)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let first = dateLabels.first! as NSString
        first.draw(at: NSPoint(x: 0, y: bottom+7), withAttributes: attributes)
        let last = dateLabels.last! as NSString
        last.draw(at: NSPoint(x: bounds.width-last.size(withAttributes: attributes).width, y: bottom+7), withAttributes: attributes)
        let caption: String
        if let hovered {
            caption = dateLabels[hovered] + " · " + Usage.exact(buckets[hovered].total) + " токенов"
        } else { caption = "Динамика расхода" }
        (caption as NSString).draw(at: NSPoint(x: 0, y: 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

final class AnalyticsDocument: NSView { override var isFlipped: Bool { true } }

final class AnalyticsController: NSWindowController {
    var exportView: NSView!
    var samples: [TokenSample] = []
    var countMode: TokenCountMode = .all {
        didSet {
            guard oldValue != countMode else { return }
            modes.selectedSegment = TokenCountMode.allCases.firstIndex(of: countMode) ?? 0
            rebuild(animated: true)
        }
    }
    var onCountModeChange: ((TokenCountMode) -> Void)?
    let modes = NSSegmentedControl(labels: TokenCountMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    var period = 1
    var selectedProject: String?
    var selectedModel: String?
    let totalLabel = NSTextField(labelWithString: "—")
    let countLabel = NSTextField(labelWithString: "—")
    let averageLabel = NSTextField(labelWithString: "—")
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
    var signature: Int?
    private var needsRebuild = true
    private var rowIndex = 0
    private var reusableRows: [AnalyticsRow] = []
    private var summaryCache: AnalyticsSummary?
    private struct Selection: Equatable {
        let period: Int
        let mode: TokenCountMode
        let project: String?
        let model: String?
    }
    private var summaryKey: Selection?
    private var cachedTotal = 0
    private var cachedRequestCount = 0
    private var cachedEstimate = false
    private var cachedRequests: [AnalyticsRequest]?
    private var cachedGroups: [Bool: [AnalyticsGroup]] = [:]
    private let requestFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "d MMM, HH:mm"; return formatter
    }()

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
        let headingRow = NSStackView(views: [heading, NSView(), modes])
        headingRow.orientation = .horizontal; headingRow.alignment = .centerY
        modes.selectedSegment = 0; modes.target = self; modes.action = #selector(changeCountMode)
        modes.setAccessibilityLabel("Режим подсчёта токенов")
        modes.toolTip = "Все: входящие и исходящие токены. Исходящие: только ответ модели."
        stack.addArrangedSubview(headingRow)
        headingRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        stack.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        chart.heightAnchor.constraint(equalToConstant: 135).isActive = true
        filterButton.isBordered = false; filterButton.font = .systemFont(ofSize: 11); filterButton.contentTintColor = .secondaryLabelColor
        filterButton.target = self; filterButton.action = #selector(clearFilter)
        stack.addArrangedSubview(filterButton)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(changeTab)
        stack.addArrangedSubview(tabs)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        // Fade only the clipped viewport, not a potentially 200-row document.
        scroll.contentView.wantsLayer = true
        chart.wantsLayer = true
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
    func update(_ snapshot: AnalyticsSnapshot) {
        guard snapshot.signature != signature else { return }
        signature = snapshot.signature
        samples = snapshot.samples
        needsRebuild = true
        summaryCache = nil
        if window?.isVisible == true { rebuild() }
    }
    func present(near badge: NSWindow) {
        if needsRebuild { rebuild() }
        if let screen = badge.screen ?? NSScreen.main, let window {
            let area = screen.visibleFrame
            let x = max(area.minX+12, min(badge.frame.midX-window.frame.width/2, area.maxX-window.frame.width-12))
            let above = badge.frame.maxY+8
            let y = above+window.frame.height <= area.maxY ? above : max(area.minY+12, min(badge.frame.minY-window.frame.height-8, area.maxY-window.frame.height-12))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    @objc func changeCountMode() {
        guard TokenCountMode.allCases.indices.contains(modes.selectedSegment) else { return }
        countMode = TokenCountMode.allCases[modes.selectedSegment]
        onCountModeChange?(countMode)
    }
    @objc func changePeriod() { period = periods.selectedSegment; rebuild(animated: true, resetScroll: true) }
    @objc func changeTab() { rebuild(animated: true, resetScroll: true) }
    @objc func clearFilter() { selectedProject = nil; selectedModel = nil; rebuild(animated: true, resetScroll: true) }
    @objc func selectGroup(_ sender: NSButton) {
        guard rowActions.indices.contains(sender.tag) else { return }
        switch rowActions[sender.tag] {
        case .expand(let project):
            if expandedProjects.contains(project) { expandedProjects.remove(project) } else { expandedProjects.insert(project) }
        case .filter(let project, let model):
            selectedProject = project; selectedModel = model; tabs.selectedSegment = 2
            scroll.contentView.scroll(to: .zero)
        }
        rebuild(animated: true)
    }
    func register(_ action: RowAction) -> Int { rowActions.append(action); return rowActions.count-1 }
    func rebuild(animated: Bool = false, resetScroll: Bool = false) {
        let position = resetScroll ? NSPoint.zero : scroll.contentView.bounds.origin
        needsRebuild = false
        rowIndex = 0
        defer {
            while reusableRows.count > rowIndex {
                let row = reusableRows.removeLast()
                rows.removeArrangedSubview(row); row.removeFromSuperview()
            }
            scroll.documentView?.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: position, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            if animated { scroll.contentView.animateContentChange(); chart.animateContentChange() }
        }
        rowActions = []
        let key = Selection(period: period, mode: countMode, project: selectedProject, model: selectedModel)
        let summary: AnalyticsSummary
        if let cached = summaryCache, key == summaryKey { summary = cached }
        else {
            summary = AnalyticsSummary(samples: samples, period: period, project: selectedProject, model: selectedModel, countMode: countMode)
            summaryCache = summary; summaryKey = key
            cachedTotal = summary.total; cachedRequestCount = summary.requestCount; cachedEstimate = summary.isEstimate
            cachedRequests = nil; cachedGroups = [:]
            chart.hourly = summary.hourly; chart.buckets = summary.buckets()
        }
        let total = cachedTotal
        let requestCount = cachedRequestCount
        let estimate = cachedEstimate
        totalLabel.stringValue = (estimate ? "≈" : "") + Usage.format(total)
        totalLabel.toolTip = Usage.exact(total) + " токенов"
        countLabel.stringValue = "\(requestCount)"
        averageLabel.stringValue = (estimate ? "≈" : "") + Usage.format(requestCount == 0 ? 0 : total / requestCount)
        let filters = [selectedProject.map { URL(fileURLWithPath: $0).lastPathComponent }, selectedModel].compactMap { $0 }
        filterButton.title = filters.isEmpty ? "Все проекты и модели" : filters.joined(separator: " · ") + "  × Сбросить"
        filterButton.isEnabled = !filters.isEmpty
        if summary.samples.isEmpty {
            addRow(title: "За этот период пока нет запросов", subtitle: "", value: "", ratio: nil, actionIndex: nil)
            groupKeys = []
            return
        }
        if tabs.selectedSegment == 2 {
            if cachedRequests == nil { cachedRequests = Array(summary.requests.prefix(200)) }
            groupKeys = []
            for request in cachedRequests ?? [] {
                let title = request.title
                let subtitle = "\(request.project) · \(requestFormatter.string(from: request.date)) · \(request.models)"
                let excerpt = request.text.count > 4000 ? String(request.text.prefix(4000)) + "…" : request.text
                addRow(title: title, subtitle: subtitle, value: (request.isEstimate ? "≈" : "") + Usage.format(request.total), ratio: nil, actionIndex: nil, tooltip: (excerpt.isEmpty ? "Текст запроса отсутствует в журнале" : excerpt) + "\n\n" + Usage.exact(request.total) + " токенов")
            }
        } else {
            let byModel = tabs.selectedSegment == 1
            if cachedGroups[byModel] == nil { cachedGroups[byModel] = summary.groups(byModel: byModel) }
            let groups = cachedGroups[byModel] ?? []
            groupKeys = groups.map(\.key)
            for group in groups {
                let share = Double(group.total) / Double(max(1, total))
                let isProject = tabs.selectedSegment == 0
                let expanded = expandedProjects.contains(group.key)
                let action = register(isProject ? .expand(group.key) : .filter(project: selectedProject, model: group.key))
                let title = isProject ? (expanded ? "▾  " : "▸  ") + group.title : group.title
                addRow(title: title, subtitle: "\(group.requests) запр. · \(Int((share*100).rounded()))%", value: (group.isEstimate ? "≈" : "") + Usage.format(group.total), ratio: share, actionIndex: action, tooltip: group.key + " · " + Usage.exact(group.total) + " токенов")
                if isProject && expanded {
                    let projectSummary = AnalyticsSummary(samples: samples, period: period, project: group.key, model: selectedModel, countMode: countMode)
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
        let row: AnalyticsRow
        if rowIndex < reusableRows.count { row = reusableRows[rowIndex] }
        else {
            row = AnalyticsRow()
            reusableRows.append(row)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        rowIndex += 1
        var hint = ""
        if let actionIndex {
            if case .expand = rowActions[actionIndex] { hint = "Развернуть или свернуть модели" }
            else { hint = "Показать запросы" }
        }
        row.configure(title: title, subtitle: subtitle, value: value, ratio: ratio,
            actionIndex: actionIndex, tooltip: tooltip, indent: indent, hint: hint, target: self)
    }
}

/// Keep labels, buttons and constraints alive across data refreshes and tab switches.
final class AnalyticsRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var leading: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!
    private var barWidth: NSLayoutConstraint!
    private var rowHeight: NSLayoutConstraint!
    private var share: CGFloat = 0
    private var indent: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium); titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10); subtitleLabel.textColor = .secondaryLabelColor; subtitleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bar.wantsLayer = true; bar.layer?.cornerRadius = 1.5
        button.isBordered = false; button.action = #selector(AnalyticsController.selectGroup(_:))
        for view in [titleLabel, subtitleLabel, valueLabel, bar, button] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        leading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        barLeading = bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        barWidth = bar.widthAnchor.constraint(equalToConstant: 0)
        rowHeight = heightAnchor.constraint(equalToConstant: 50)
        NSLayoutConstraint.activate([
            leading, rowHeight, barLeading, barWidth,
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), valueLabel.topAnchor.constraint(equalTo: titleLabel.topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3), bar.heightAnchor.constraint(equalToConstant: 3),
            button.leadingAnchor.constraint(equalTo: leadingAnchor), button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor), button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        let width = max(0, (bounds.width - indent - 8) * share)
        if barWidth.constant != width { barWidth.constant = width }
        super.layout()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
    }
    func configure(title: String, subtitle: String, value: String, ratio: Double?, actionIndex: Int?, tooltip: String?, indent: CGFloat, hint: String, target: AnalyticsController) {
        for (label, text) in [(titleLabel, title), (subtitleLabel, subtitle), (valueLabel, value)] {
            if label.stringValue != text { label.stringValue = text }
        }
        if toolTip != tooltip {
            toolTip = tooltip; titleLabel.toolTip = tooltip; subtitleLabel.toolTip = tooltip; button.toolTip = tooltip
        }
        leading.constant = 2 + indent; barLeading.constant = 2 + indent
        rowHeight.constant = ratio == nil ? 43 : 50
        share = CGFloat(ratio.map { max(0.001, min(1, $0)) } ?? 0); self.indent = indent
        bar.isHidden = ratio == nil
        bar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        needsLayout = true
        button.isHidden = actionIndex == nil
        button.tag = actionIndex ?? -1; button.target = target
        if actionIndex != nil { button.setAccessibilityLabel("\(title), \(value) токенов. \(hint)") }
    }
}
