import AppKit

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
func pump(_ duration: TimeInterval = 0.12) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        NSApp.updateWindows()
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 60), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let badge = BadgeView(frame: window.contentView!.bounds)
window.contentView = badge
var usage = Usage()
usage.running = true; usage.tokens = Tokens(["input_tokens": 100_000]); usage.remainingLimit = 86
badge.requestVisibility = 1; badge.usage = usage
window.orderFrontRegardless()
pump()

var frames = 0
var clock: AnimationClock? = AnimationClock(view: badge)
clock?.onFrame = { _, _ in frames += 1 }
clock?.setActive(true)
pump(0.2)
if clock!.canAnimate {
    check(clock!.isRunning && frames > 0, "A visible active clock must receive display frames")
}
clock?.setActive(false)
let stoppedFrames = frames
pump()
check(!clock!.isRunning && frames == stoppedFrames, "An idle clock must stop producing frames")
clock?.setActive(true)
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
check(!clock!.isRunning, "Screen sleep must pause the clock immediately")
let sleepingFrames = frames
pump()
check(frames == sleepingFrames, "Screen sleep must produce no frames")
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
pump()
if clock!.canAnimate { check(clock!.isRunning, "Screen wake must resume the clock") }
window.orderOut(nil)
pump(0.6)
check(!clock!.isRunning, "An occluded window must pause its clock")
let hiddenFrames = frames
pump()
check(frames == hiddenFrames, "A hidden clock must not wake up to render")
window.orderFrontRegardless()
pump()
if clock!.canAnimate { check(clock!.isRunning && frames > hiddenFrames, "The clock must resume after showing the window") }
weak var releasedClock = clock
clock = nil
check(releasedClock == nil, "An active display link must not retain its owner")

var finished = false
badge.numberFrame = { _, finish in finished = finish; return !finish }
window.orderOut(nil)
pump(0.6)
check(finished && badge.numberFrame == nil, "Hiding the badge must finish and release its finite transition")
window.orderFrontRegardless()
pump()

let now = Date()
func sample(_ index: Int, tokens: Int = 1000) -> TokenSample {
    TokenSample(id: "response-\(index)", request: "request-\(index)", date: now.addingTimeInterval(-Double(index) * 60),
        project: "Проект \(index % 5)", projectPath: "/projects/\(index % 5)", model: "Модель \(index % 3)",
        tokens: Tokens(["input_tokens": tokens, "output_tokens": 100]), authoritative: true,
        requestText: "Проверь плавность переключения и обновления данных \(index)")
}
let samples = (0..<250).map { sample($0) }
let snapshot = AnalyticsSnapshot(samples: samples, now: now)
check(snapshot.signature == AnalyticsSnapshot(samples: samples, now: now).signature, "Unchanged history must have a stable signature")
let changedDate = TokenSample(id: samples[0].id, request: samples[0].request, date: now.addingTimeInterval(-86400),
    project: samples[0].project, projectPath: samples[0].projectPath, model: samples[0].model, tokens: samples[0].tokens,
    authoritative: true, requestText: samples[0].requestText)
check(snapshot.signature != AnalyticsSnapshot(samples: [changedDate] + Array(samples.dropFirst()), now: now).signature, "Date corrections must invalidate analytics")
check(snapshot.signature != AnalyticsSnapshot(samples: samples, now: now.addingTimeInterval(3600)).signature, "A new hour must extend the chart even without new samples")
let controller = AnalyticsController()
controller.update(snapshot)
controller.present(near: window)
pump()
controller.exportView.layoutSubtreeIfNeeded()
check(controller.rows.arrangedSubviews.count == 5, "Project rows must render")
let firstRow = controller.rows.arrangedSubviews[0]
controller.chart.hovered = 1
controller.update(snapshot)
check(controller.rows.arrangedSubviews[0] === firstRow && controller.chart.hovered == 1, "An unchanged update must preserve rows and hover")
var changed = samples
changed[0] = sample(0, tokens: 9000)
controller.update(AnalyticsSnapshot(samples: changed, now: now))
check(controller.rows.arrangedSubviews[0] === firstRow && controller.chart.hovered == 1, "Data updates must reuse rows and preserve hover")

func capture(_ view: NSView, _ name: String) throws {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
    try png.write(to: output.appendingPathComponent(name + ".png"))
}
try capture(controller.exportView, "projects")
let selection = NSButton(); selection.tag = 0
controller.selectGroup(selection)
controller.exportView.layoutSubtreeIfNeeded()
check(controller.rows.arrangedSubviews.count == 9, "Expanding a project must show its models and action")
try capture(controller.exportView, "expanded")
controller.tabs.selectedSegment = 2
controller.changeTab()
controller.exportView.layoutSubtreeIfNeeded()
check(controller.rows.arrangedSubviews.count == 200, "Requests must stay bounded at 200 rows")
let requestRow = controller.rows.arrangedSubviews[0]
controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
controller.scroll.reflectScrolledClipView(controller.scroll.contentView)
controller.rebuild()
check(controller.rows.arrangedSubviews[0] === requestRow, "A request refresh must reuse views")
check(abs(controller.scroll.contentView.bounds.origin.y - 300) < 1, "A data refresh must preserve scroll position")
controller.tabs.selectedSegment = 1
controller.changeTab()
controller.exportView.layoutSubtreeIfNeeded()
check(controller.rows.arrangedSubviews.count == 3 && controller.scroll.contentView.bounds.origin.y == 0, "A tab switch must reset scrolling")
try capture(controller.exportView, "models")
controller.selectGroup(selection)
check(controller.tabs.selectedSegment == 2 && controller.selectedModel != nil, "A reused button must filter the current model")
try capture(controller.exportView, "requests")
controller.countMode = .outgoing
check(controller.totalLabel.toolTip == Usage.exact(100 * 84) + " токенов", "Mode switches must invalidate cached summaries")
controller.clearFilter()
check(controller.totalLabel.toolTip == Usage.exact(100 * 250) + " токенов", "Clearing a filter must recompute totals")
controller.chart.hovered = 100
controller.chart.buckets = []
check(controller.chart.hovered == nil, "Shrinking a chart must clear an invalid hover index")
// Content changes must never select a third width in either lifecycle state.
var compactUsage = usage
compactUsage.running = true
compactUsage.tokens = Tokens(["input_tokens": 1])
let compactWidth = BadgeView.preferredWidth(for: compactUsage)
var largeUsage = compactUsage
largeUsage.tokens = Tokens(["input_tokens": 1_000_000])
let exactWidth = BadgeView.preferredWidth(for: largeUsage)
check(compactWidth == exactWidth && exactWidth == BadgeView.expandedWidth, "All active counts must use one fixed width")
largeUsage.isEstimate = true
check(BadgeView.preferredWidth(for: largeUsage) == exactWidth, "The estimate marker must not resize the badge")
var parallelUsage = compactUsage
parallelUsage.activeRequestIDs = Set((0..<128).map { "parallel-\($0)" })
check(BadgeView.preferredWidth(for: parallelUsage) == compactWidth, "Parallel requests must not resize the badge")
for running in [false, true] {
    for mode in TokenCountMode.allCases {
        for count in [0, 999, 1_000, 999_999, 1_000_000, Int.max] {
            for days: Double? in [nil, 0, 1, 7, 30, 999] {
                var example = parallelUsage
                example.running = running; example.countMode = mode
                example.tokens = Tokens(["input_tokens": count])
                example.limitResetAt = days.map { Date().addingTimeInterval($0 * 86400).timeIntervalSince1970 }
                let expected = running ? BadgeView.expandedWidth : BadgeView.collapsedWidth
                check(BadgeView.preferredWidth(for: example) == expected, "Only running status may determine width")
            }
        }
    }
}
var hugeUsage = largeUsage
hugeUsage.tokens = Tokens(["input_tokens": Int.max])
for (name, example) in [("badge-compact", compactUsage), ("badge-estimate", largeUsage), ("badge-parallel", parallelUsage), ("badge-huge", hugeUsage)] {
    badge.requestVisibility = 1; badge.usage = example
    window.setContentSize(NSSize(width: BadgeView.preferredWidth(for: example), height: 60))
    try capture(badge, name)
}
for (name, count) in [("badge-low", 10_000), ("badge-high", 1_000_000), ("badge-idle", 0)] {
    usage.tokens = Tokens(["input_tokens": count]); usage.running = count > 0
    badge.requestVisibility = usage.running ? 1 : 0
    badge.usage = usage
    window.setContentSize(NSSize(width: BadgeView.preferredWidth(for: usage), height: 60))
    try capture(badge, name)
}
controller.close()
usage.limitResetAt = Date().addingTimeInterval(3 * 86400).timeIntervalSince1970
usage.limitWindowDuration = 7 * 86400
badge.usage = usage
let resetDeadline = Date().addingTimeInterval(12)
while badge.accessibilityLabel()?.contains("До сброса лимита") != true && Date() < resetDeadline {
    pump(0.1)
}
check(badge.accessibilityLabel()?.contains("До сброса лимита") == true, "The limit transition must finish even when the flame is idle")
try capture(badge, "badge-reset")
let shortResetWidth = BadgeView.preferredWidth(for: usage)
usage.limitResetAt = Date().addingTimeInterval(999 * 86400).timeIntervalSince1970
badge.usage = usage
check(BadgeView.preferredWidth(for: usage) == shortResetWidth && shortResetWidth == BadgeView.collapsedWidth, "Reset countdowns must not resize an idle badge")
window.setContentSize(NSSize(width: BadgeView.preferredWidth(for: usage), height: 60))
try capture(badge, "badge-long-reset")
usage.limitResetAt = nil
badge.usage = usage
check(badge.accessibilityLabel()?.contains("Использовано лимита") == true, "Removing reset data must restore the usage caption")
window.orderOut(nil)
pump(0.6)
print("Animation/UI checks passed: frame lifecycle, row reuse, filters, modes, hover, scrolling and snapshots")
