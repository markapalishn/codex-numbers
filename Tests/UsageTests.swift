import Foundation

func event(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    ["type": "event_msg", "timestamp": "2026-09-14T12:00:00Z", "payload": extra.merging(["type": type]) { _, b in b }]
}
func token(_ input: Int, _ cached: Int, _ output: Int, last: Int = 100) -> [String: Any] {
    event("token_count", ["info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output], "last_token_usage": ["total_tokens": last], "model_context_window": 1000]])
}
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}
let r = SessionReader()
r.consume(event("task_started"))
r.consume(token(100, 80, 5))
r.consume(token(100, 80, 5))
r.consume(token(220, 180, 12, last: 410))
check(r.usage!.tokens.input == 220, "Sum calls, ignore duplicate")
r.consume(event("task_complete"))
check(!r.usage!.running, "Completion")
check(r.usage!.badgeUsage.requestTokens == 0 && r.usage!.requestTokens == 232, "Idle badge clears while completed total is retained")
r.consume(event("task_started"))
r.consume(token(270, 220, 15))
check(r.usage!.badgeUsage.requestTokens == 53, "Active badge shows current turn")
check(r.usage!.tokens.input == 50 && r.usage!.tokens.output == 3, "New turn delta")
r.consume(event("token_count", ["info": NSNull()]))
check(r.usage!.tokens.input == 50, "Ignore rate limit only event")
r.consume(event("turn_aborted"))
check(!r.usage!.running, "Abort")
check(r.usage!.badgeUsage.requestTokens == 0, "Abort clears badge")
r.consume(event("task_started"))
r.consume(token(20, 10, 2))
check(r.usage!.tokens.input == 20, "Counter reset")
r.consume(event("task_complete"))
r.consume(event("task_started"))
r.consume(event("task_complete"))
check(r.usage!.requestTokens == 0, "Empty new turn does not reuse previous tokens")
let fragmented = SessionReader()
let bytes = try! JSONSerialization.data(withJSONObject: token(42, 10, 2)) + Data([10])
fragmented.consume(bytes.prefix(15))
check(fragmented.usage == nil, "Wait for full JSONL record")
fragmented.consume(bytes.dropFirst(15))
check(fragmented.usage!.tokens.input == 42, "Resume partial record")
fragmented.consume(Data("invalid\n".utf8))
check(fragmented.usage!.tokens.input == 42, "Ignore malformed record")
check(Usage.format(105000) == "105 тыс." && Usage.format(1400) == "1,4 тыс.", "Formatting")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("session.jsonl")
try! bytes.write(to: file)
let monitor = UsageMonitor(root: dir)
check(monitor.poll()!.tokens.input == 42, "Discover session")
check(monitor.poll()!.tokens.input == 42, "No double counting on poll")
let handle = try! FileHandle(forWritingTo: file)
try! handle.seekToEnd()
try! handle.write(contentsOf: JSONSerialization.data(withJSONObject: token(100, 20, 4)) + Data([10]))
try! handle.close()
check(monitor.poll()!.tokens.input == 100, "Tail appended events")
check(monitor.poll()!.requestTokens == 104, "Input plus output, cached not counted twice")
let limits: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 11, "resets_at": 4_000_000_000.0]]
r.consume(event("token_count", ["info": NSNull(), "rate_limits": limits]))
check(r.limit?.remaining() == 89, "Rate-only event updates remaining limit")
check(r.limit?.remaining(now: 4_000_000_001) == nil, "Expired limit is unknown")
let separate: [String: Any] = ["limit_id": "codex_bengalfox", "primary": ["used_percent": 90, "resets_at": 4_000_000_000.0]]
r.consume(event("token_count", ["rate_limits": separate]))
check(r.limit?.remaining() == 89, "Separate model limit cannot overwrite Codex allowance")
let multiple: [String: Any] = ["primary": ["used_percent": 11, "resets_at": 4_000_000_000.0], "secondary": ["used_percent": 40, "resets_at": 4_000_000_000.0]]
check(LimitSnapshot(multiple, timestamp: "")?.remaining() == 60, "Use most constrained window")
let rateData = try! JSONSerialization.data(withJSONObject: event("token_count", ["rate_limits": limits])) + Data([10])
let writer = try! FileHandle(forWritingTo: file)
try! writer.seekToEnd(); try! writer.write(contentsOf: rateData); try! writer.close()
check(monitor.poll()!.remainingLimit == 89, "Monitor combines latest usage with rate snapshot")
check(monitor.poll()!.line == "Запрос: 104 токенов · Остаток лимита: 89%", "Requested display")
let analyticsReader = SessionReader()
analyticsReader.consume(["type": "session_meta", "payload": ["id": "test-session", "cwd": "/projects/alpha"]])
analyticsReader.consume(event("task_started", ["turn_id": "turn-a"]))
analyticsReader.consume(["type": "turn_context", "payload": ["model": "model-a", "turn_id": "turn-a", "cwd": "/projects/alpha"]])
analyticsReader.consume(token(100, 80, 5))
analyticsReader.consume(token(100, 80, 5))
analyticsReader.consume(["type": "turn_context", "payload": ["model": "model-b", "turn_id": "turn-a"]])
analyticsReader.consume(token(220, 180, 12))
let now = TokenSample.parseDate("2026-09-14T13:00:00Z")!
let summary = AnalyticsSummary(samples: analyticsReader.samples, period: 0, now: now)
check(summary.total == 232 && summary.requestCount == 1, "Calls summed into one request, duplicates ignored")
check(summary.groups(byModel: true).count == 2, "Model switch attributed per call")
check(summary.groups(byModel: false).first?.title == "alpha", "Project attribution")
check(summary.buckets().reduce(0) { $0 + $1.total } == summary.total, "Chart and total agree")
check(AnalyticsSummary(samples: analyticsReader.samples, period: 0, model: "model-a", now: now).total == 105, "Model filter")
check(AnalyticsSummary(samples: analyticsReader.samples, period: 0, project: "/projects/other", now: now).total == 0, "Project filter")
check(AnalyticsSummary(samples: analyticsReader.samples, period: 0, now: now.addingTimeInterval(86400)).total == 0, "Period boundary")
let copied = SessionReader()
copied.samples = analyticsReader.samples
monitor.readers[dir.appendingPathComponent("copy-a")] = analyticsReader
monitor.readers[dir.appendingPathComponent("copy-b")] = copied
check(monitor.analyticsSamples().filter { $0.request == "turn-a" }.count == 2, "Copied history counted only once")
copied.isChild = true
check(monitor.analyticsSamples().filter { $0.request == "turn-a" }.count == 2, "Child sessions excluded")
print("All usage and analytics tests passed")
