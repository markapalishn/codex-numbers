import Foundation

let auditNow = TokenSample.parseDate("2026-09-14T13:00:00Z")!
var tick = 0
func stamp() -> String { tick += 1; return String(format: "2026-09-14T12:%02d:%02dZ", tick/60, tick%60) }
func event(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
    ["type": "event_msg", "timestamp": stamp(), "payload": extra.merging(["type": type]) { _, b in b }]
}
func counts(_ input: Int, _ cached: Int = 0, _ output: Int = 0) -> [String: Any] {
    ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]
}
func token(_ input: Int, _ cached: Int = 0, _ output: Int = 0) -> [String: Any] {
    event("token_count", ["info": ["total_token_usage": counts(input,cached,output)]])
}
func record(_ response: String, _ turn: String, _ input: Int, _ cached: Int = 0, _ output: Int = 0, root: String? = nil, session: String = "parent", checkpoint: [String: Any]? = nil) -> [String: Any] {
    var payload: [String: Any] = ["response_id": response, "turn_id": turn, "root_turn_id": root ?? turn, "session_id": session, "usage": counts(input,cached,output)]
    if let checkpoint { payload["turn_token_usage"] = checkpoint }
    return ["type": "token_usage_record", "timestamp": stamp(), "payload": payload]
}
func context(_ turn: String, _ model: String, path: String = "/projects/alpha") -> [String: Any] {
    ["type": "turn_context", "timestamp": stamp(), "payload": ["turn_id": turn, "model": model, "cwd": path]]
}
func reader(_ session: String = "parent", path: String = "/projects/alpha") -> SessionReader {
    let r = SessionReader()
    r.consume(["type": "session_meta", "payload": ["id": session, "cwd": path]])
    return r
}
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
func data(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) + Data([10]) }

let r = reader()
r.consume(event("task_started", ["turn_id": "turn-a"]))
r.consume(context("turn-a", "model-a"))
let first = record("response-1", "turn-a", 100, 80, 5)
r.consume(first); r.consume(first)
r.consume(token(100,80,5))
check(r.usage!.requestTokens == 105 && !r.usage!.isEstimate, "Direct response once; cached not added; token_count not added")
r.consume(context("turn-a", "model-b"))
// Compaction response is absent from the old cumulative counter.
r.consume(record("compaction", "turn-a", 200, 150, 10))
r.consume(["type": "compacted", "payload": [:]])
r.consume(token(100,80,5))
let turnCheckpoint = counts(350,250,18)
r.consume(record("response-3", "turn-a", 50, 20, 3, checkpoint: turnCheckpoint))
r.consume(token(150,100,8))
check(r.usage!.requestTokens == 368, "Compaction retained even when old counter does not grow")
check(r.usage!.tokens == Tokens(turnCheckpoint), "Matches Codex turn checkpoint")
r.consume(event("task_complete", ["turn_id": "turn-a"]))
check(r.usage!.badgeUsage.requestTokens == 0 && r.usage!.requestTokens == 368, "Completed turn preserved in history; idle badge zero")
r.consume(event("task_started", ["turn_id": "turn-b"]))
check(r.usage!.requestTokens == 0 && r.usage!.running, "New request starts at zero")
r.consume(record("response-b", "turn-b", 20,10,2))
r.consume(event("turn_aborted", ["turn_id": "turn-b"]))
check(!r.usage!.running && r.usage!.badgeUsage.requestTokens == 0, "Abort clears badge")
// A late record belongs to its explicit ID, never to the last current turn.
r.consume(record("late-a", "turn-a", 10,0,1))
check(r.states["turn-a"]?.usage.running == false, "Late response cannot reopen completion")
check(r.samples.filter { $0.localTurn == "turn-b" }.reduce(0) { $0 + TokenCountMode.all.count($1.tokens) } == 22, "Late response cannot leak into another turn")

let legacy = reader("legacy")
legacy.consume(event("task_started", ["turn_id": "old-turn"]))
let legacyToken = token(100,80,5)
legacy.consume(legacyToken); legacy.consume(legacyToken); legacy.consume(token(220,180,12))
check(legacy.usage!.requestTokens == 232 && legacy.usage!.isEstimate, "Legacy counters remain available as estimates")
legacy.consume(event("task_started", ["turn_id": "old-next"]))
legacy.consume(token(270,220,15))
check(legacy.usage!.requestTokens == 53, "Legacy baseline is per session, not reset per turn")
legacy.consume(token(20,10,2))
check(legacy.usage!.requestTokens == 75, "Legacy counter reset")
// Prefer explicit records for the same turn even if the cumulative event came first.
legacy.consume(record("old-promoted", "old-next", 30,10,3, session: "legacy"))
check(legacy.usage!.requestTokens == 33 && !legacy.usage!.isEstimate, "Authoritative turn replaces fallback, never sums both")

let fragmented = reader("fragmented")
let bytes = data(record("fragment", "f-turn", 42,10,2, session: "fragmented"))
fragmented.consume(bytes.prefix(15)); check(fragmented.usage == nil, "Partial JSONL waits")
fragmented.consume(bytes.dropFirst(15)); fragmented.consume(Data("invalid\n".utf8))
check(fragmented.usage!.requestTokens == 44, "Partial and malformed lines handled")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("session.jsonl")
try! bytes.write(to: file)
let monitor = UsageMonitor(root: dir)
check(monitor.poll()!.requestTokens == 44 && monitor.poll()!.requestTokens == 44, "Tail reread never duplicates")
let handle = try! FileHandle(forWritingTo: file)
try! handle.seekToEnd(); try! handle.write(contentsOf: data(record("fragment-2", "f-turn", 50,0,3))); try! handle.close()
check(monitor.poll()!.requestTokens == 97, "Appended records counted")
check(monitor.polledSamples.reduce(0) { $0 + TokenCountMode.all.count($1.tokens) } == 97, "Polling snapshot updates after append")
check(monitor.poll()!.requestTokens == 97 && monitor.polledSamples.count == 2, "Unchanged poll reuses a complete history")
try! data(record("replacement", "new", 1)).write(to: file)
check(monitor.poll()!.requestTokens == 1 && monitor.analyticsSamples().count == 1, "Truncation resets all parser state")
check(monitor.polledSamples.count == 1 && TokenCountMode.all.count(monitor.polledSamples[0].tokens) == 1, "Truncation invalidates the polling snapshot")

let parent = reader()
parent.consume(event("task_started", ["turn_id": "root"]))
parent.consume(context("root", "parent-model"))
parent.consume(["type": "response_item", "payload": ["role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions\nLocal instructions"]]]])
parent.consume(["type": "response_item", "payload": ["role": "user", "content": [["type": "input_text", "text": "Исправь оплату\nи добавь проверку"]]]])
parent.consume(event("user_message", ["message": "Дополнение", "turn_id": "root"]))
let parentRecord = record("parent-call", "root", 100,80,5)
parent.consume(parentRecord)
let child = reader("child", path: "/scratch/worker")
child.consume(event("task_started", ["turn_id": "child-turn"]))
child.consume(context("child-turn", "child-model", path: "/scratch/worker"))
let childRecord = record("child-call", "child-turn", 200,100,10, root: "root", session: "child")
child.consume(childRecord)
let copy = reader("copy")
copy.consume(parentRecord); copy.consume(childRecord)
let joined = UsageMonitor(root: dir)
joined.readers = [dir.appendingPathComponent("p"):parent, dir.appendingPathComponent("c"):child, dir.appendingPathComponent("copy"):copy]
let joinedSamples = joined.analyticsSamples()
check(joinedSamples.allSatisfy { $0.requestText == "Исправь оплату\nи добавь проверку" }, "Root message title inherited by child and copied records")
check(joinedSamples.count == 2 && joinedSamples.allSatisfy { $0.request == "root" }, "Child belongs to parent; duplicates across journals excluded")
check(joinedSamples.allSatisfy { $0.projectPath == "/projects/alpha" }, "Child attributed to parent project")
check(joined.selectedUsage(now: auditNow)!.requestTokens == 315, "Live root includes child usage")
let other = reader("other")
other.consume(event("task_started", ["turn_id": "other-turn"]))
joined.readers[dir.appendingPathComponent("o")] = other
check(joined.selectedUsage(now: auditNow)!.activeRequestCount == 2 && joined.selectedUsage(now: auditNow)!.requestTokens == 315, "New parallel request counted before first token event; child is not a separate request")
other.consume(record("other-call", "other-turn", 999, 0, 20, session: "other"))
check(joined.selectedUsage(now: auditNow)!.requestTokens == 1334, "Parallel badge sums both active roots")
var parallelOutput = joined.selectedUsage(now: auditNow)!
parallelOutput.countMode = .outgoing
check(parallelOutput.requestTokens == 35 && parallelOutput.requestCaption == "В работе: 2", "Parallel badge labels request count without mode suffix")
var repeatedParent = parentRecord
repeatedParent["timestamp"] = stamp()
parent.consume(repeatedParent)
check(joined.selectedUsage(now: auditNow)!.requestTokens == 1334, "Latest event moving to another root cannot switch or duplicate badge total")
other.consume(event("task_complete", ["turn_id": "other-turn"]))
joined.readers[dir.appendingPathComponent("o")] = other
check(joined.selectedUsage(now: auditNow)!.requestTokens == 315 && joined.selectedUsage(now: auditNow)!.running, "Completed parallel turn cannot hide active root or mix totals")
check(joined.selectedUsage(now: auditNow)!.activeRequestCount == 1, "Completed parallel root removed from active count")
parent.consume(event("task_complete", ["turn_id": "root"]))
check(joined.selectedUsage(now: auditNow)!.running && joined.selectedUsage(now: auditNow)!.activeRequestCount == 1, "Child can outlive parent without adding a request")
child.consume(event("task_complete", ["turn_id": "child-turn"]))
check(!joined.selectedUsage(now: auditNow)!.running && joined.selectedUsage(now: auditNow)!.badgeUsage.requestTokens == 0, "Parent and child done collapses badge")

check(joined.selectedUsage(now: auditNow)!.activeRequestCount == 0, "All requests completed clears active count")
let aborted = reader("aborted")
aborted.consume(event("task_started", ["turn_id": "abort-parallel"]))
aborted.consume(record("abort-call", "abort-parallel", 70, 0, 3, session: "aborted"))
joined.readers[dir.appendingPathComponent("aborted")] = aborted
check(joined.selectedUsage(now: auditNow)!.requestTokens == 73, "New active request excludes completed history")
aborted.consume(event("turn_aborted", ["turn_id": "abort-parallel"]))
check(joined.selectedUsage(now: auditNow)!.badgeUsage.requestTokens == 0 && joined.selectedUsage(now: auditNow)!.activeRequestCount == 0, "Aborted request removed from badge")
let stale = reader("stale")
stale.consume(["type": "event_msg", "timestamp": "2026-03-12T23:01:27Z", "payload": ["type": "task_started", "turn_id": "stale-turn"]])
joined.readers[dir.appendingPathComponent("stale")] = stale
check(!joined.selectedUsage(now: auditNow)!.running, "Unmatched old start cannot revive a stale task")
let fallbackCopy = reader("fallback-copy")
fallbackCopy.consume(context("root", "parent-model"))
fallbackCopy.consume(token(999_999))
joined.readers[dir.appendingPathComponent("fallback-copy")] = fallbackCopy
check(joined.analyticsSamples().filter { $0.request == "root" }.reduce(0) { $0 + TokenCountMode.all.count($1.tokens) } == 315, "Modern records suppress fallback across different files")
let now = auditNow
let summary = AnalyticsSummary(samples: joinedSamples, period: 0, now: now)
check(summary.requests.first?.title == "Исправь оплату и добавь проверку", "Readable request title from first user message")
check(RequestText.title(String(repeating: "я", count: 150)).count == 100, "Long title truncated without breaking Unicode")
check(summary.total == 315 && summary.requestCount == 1, "One user request includes both models")
check(summary.groups(byModel: true).count == 2 && summary.groups(byModel: false).count == 1, "Models split; root project joined")
check(summary.buckets().reduce(0) { $0+$1.total } == summary.total, "Chart agrees with total")
check(AnalyticsSummary(samples: joinedSamples, period: 0, model: "child-model", now: now).total == 210, "Model filter")
check(AnalyticsSummary(samples: joinedSamples, period: 0, now: now.addingTimeInterval(86400)).total == 0, "Period boundary")
let limits: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 11, "window_minutes": 10_080, "resets_at": 4_000_000_000.0]]
parent.consume(event("token_count", ["info": NSNull(), "rate_limits": limits]))
check(joined.selectedUsage(now: auditNow)!.remainingLimit == 89, "Limits still update without token records")
check(joined.selectedUsage(now: auditNow)!.limitResetAt == 4_000_000_000, "Reset time follows the displayed limit window")
check(joined.selectedUsage(now: auditNow)!.limitWindowDuration == 604_800, "Limit window duration is preserved for the countdown graph")
check(parent.limit?.current(now: 4_000_000_001) == nil, "Expired reset time is unknown")
let twoWindows = LimitSnapshot(["limit_id": "codex",
    "primary": ["used_percent": 17.0, "window_minutes": 300.0, "resets_at": 4_100_000_000.0],
    "secondary": ["used_percent": 63.0, "window_minutes": 10_080.0, "resets_at": 4_200_000_000.0]], timestamp: "")!
check(twoWindows.current(now: auditNow.timeIntervalSince1970)?.remaining == 37 &&
      twoWindows.current(now: auditNow.timeIntervalSince1970)?.resets == 4_200_000_000 &&
      twoWindows.current(now: auditNow.timeIntervalSince1970)?.duration == 604_800,
      "Reset time belongs to the limit window whose usage is displayed")
check(LimitSnapshot(["limit_id": "another-model"], timestamp: "") == nil, "Unrelated limit ignored")
check(Usage.format(999) == "999" && Usage.format(1400) == "1,4 тыс." &&
      Usage.format(200_000) == "200 тыс." && Usage.format(999_999) == "1 млн" &&
      Usage.format(1_000_000) == "1 млн" && Usage.format(2_500_000) == "2,5 млн" &&
      Usage.format(1_000_000_000) == "1 млрд" &&
      Usage.format(Int.max) == "9,22 квинтлн", "Compact token formatting")
let early = reader("early")
early.consume(["type": "response_item", "payload": ["role": "user", "content": [["type": "input_text", "text": "Сообщение перед стартом"]]]])
early.consume(event("task_started", ["turn_id": "early-turn"]))
check(early.states["early-turn"]?.requestText == "Сообщение перед стартом", "Message before lifecycle event preserved")
let outgoing = AnalyticsSummary(samples: joinedSamples, period: 0, countMode: .outgoing, now: now)
check(outgoing.total == 15 && outgoing.requestCount == summary.requestCount, "Outgoing includes parent and child output, preserving request count")
check(outgoing.groups(byModel: true).map(\.total).sorted() == [5, 10], "Outgoing model groups")
check(outgoing.groups(byModel: false).first?.total == 15 && outgoing.requests.first?.total == 15, "Outgoing project and request totals")
check(outgoing.buckets().reduce(0) { $0 + $1.total } == 15, "Outgoing chart agrees with total")
check(AnalyticsSummary(samples: joinedSamples, period: 0, model: "child-model", countMode: .outgoing, now: now).total == 10, "Outgoing respects model filter")
var switched = Usage()
switched.tokens = Tokens(["input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 5])
switched.running = true; switched.remainingLimit = 89
switched.countMode = .outgoing
check(switched.requestTokens == 5 && switched.badgeUsage.requestTokens == 5 && switched.remainingLimit == 89, "Outgoing badge preserves independent limit")
check(switched.requestCaption == "Запрос", "Single request caption has no status or count-mode suffix")
switched.activeRequestIDs = ["one", "two"]
check(switched.requestCaption == "В работе: 2", "Parallel request caption has no dot suffix")
switched.running = false
check(switched.badgeUsage.requestTokens == 0, "Idle outgoing badge stays empty")
switched.countMode = .all
check(switched.requestTokens == 105, "Switching back restores all tokens without adding cache again")
let preferencesName = "CodexNumbersTests-" + UUID().uuidString
let preferences = UserDefaults(suiteName: preferencesName)!
check(TokenCountMode.load(from: preferences) == .all, "Default mode is all")
preferences.set("outgoing", forKey: TokenCountMode.defaultsKey)
check(TokenCountMode.load(from: preferences) == .outgoing, "Saved outgoing mode restored")
preferences.set("unknown", forKey: TokenCountMode.defaultsKey)
check(TokenCountMode.load(from: preferences) == .all, "Unknown preference falls back to all")
preferences.removePersistentDomain(forName: preferencesName)
print("All usage and analytics tests passed")
