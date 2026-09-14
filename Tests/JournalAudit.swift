import Foundation

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex").appendingPathComponent("sessions")
let monitor = UsageMonitor(root: root)
let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
var reference: [String: (turn: String, tokens: Tokens)] = [:]
var checkpoint: [String: Tokens] = [:]
var fileCount = 0
for case let url as URL in files where url.pathExtension == "jsonl" {
    let reader = SessionReader(); reader.read(url); monitor.readers[url] = reader; fileCount += 1
    // Independent full-file decode verifies the streaming parser against the raw records.
    let data = try Data(contentsOf: url)
    for line in data.split(separator: 10) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "token_usage_record",
              let p = object["payload"] as? [String: Any], let id = p["response_id"] as? String,
              let turn = p["turn_id"] as? String, let raw = p["usage"] as? [String: Any] else { continue }
        reference[id] = (turn, Tokens(raw))
        if let raw = p["turn_token_usage"] as? [String: Any] {
            let next = Tokens(raw)
            if next.input + next.output >= (checkpoint[turn].map { $0.input + $0.output } ?? 0) { checkpoint[turn] = next }
        }
    }
}
let actual = monitor.analyticsSamples().filter(\.authoritative)
let actualIDs = Set(actual.map(\.id))
let expectedIDs = Set(reference.keys)
var actualTotals: [String: Tokens] = [:]
for sample in actual { actualTotals[sample.localTurn, default: Tokens()].add(sample.tokens) }
var referenceTotals: [String: Tokens] = [:]
for value in reference.values { referenceTotals[value.turn, default: Tokens()].add(value.tokens) }
let recordMismatches = referenceTotals.filter { actualTotals[$0.key] != $0.value }.count
let checkpointMismatches = checkpoint.filter { actualTotals[$0.key] != $0.value }.count
print("Files: \(fileCount); unique responses: \(reference.count); turns: \(referenceTotals.count)")
print("Response ID differences: \(actualIDs.symmetricDifference(expectedIDs).count); per-turn record mismatches: \(recordMismatches)")
print("Codex turn checkpoints: \(checkpoint.count); mismatches: \(checkpointMismatches)")
print("Legacy estimated samples: \(monitor.analyticsSamples().filter { !$0.authoritative }.count)")
if !reference.isEmpty && actualIDs == expectedIDs && recordMismatches == 0 && checkpointMismatches == 0 {
    print("Journal audit passed")
} else {
    fputs("Audit needs attention; check missing history or format changes.\n", stderr)
    exit(1)
}
