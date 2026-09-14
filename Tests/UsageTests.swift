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
check(r.usage!.context == 41, "Context must use last call")
r.consume(event("task_complete"))
check(!r.usage!.running, "Completion")
r.consume(event("task_started"))
r.consume(token(270, 220, 15))
check(r.usage!.tokens.input == 50 && r.usage!.tokens.output == 3, "New turn delta")
r.consume(event("token_count", ["info": NSNull()]))
check(r.usage!.tokens.input == 50, "Ignore rate limit only event")
r.consume(event("turn_aborted"))
check(!r.usage!.running, "Abort")
r.consume(event("task_started"))
r.consume(token(20, 10, 2))
check(r.usage!.tokens.input == 20, "Counter reset")
let previous = r.usage!.tokens
r.consume(event("task_complete"))
r.consume(event("task_started"))
r.consume(event("task_complete"))
check(r.usage!.tokens == previous, "Empty turn preserves last measured request")
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
print("All usage tests passed")
