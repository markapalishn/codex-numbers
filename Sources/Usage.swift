import Foundation

struct Tokens: Equatable {
    var input = 0, cached = 0, output = 0
    init(_ raw: [String: Any] = [:]) {
        input = raw["input_tokens"] as? Int ?? 0
        cached = raw["cached_input_tokens"] as? Int ?? 0
        output = raw["output_tokens"] as? Int ?? 0
    }
    static func - (a: Tokens, b: Tokens) -> Tokens {
        Tokens(["input_tokens": max(0, a.input-b.input), "cached_input_tokens": max(0, a.cached-b.cached), "output_tokens": max(0, a.output-b.output)])
    }
    mutating func add(_ b: Tokens) { input += b.input; cached += b.cached; output += b.output }
}

struct Usage {
    var tokens = Tokens()
    var context: Int?
    var timestamp = ""
    var running = false
    var project = "Codex"
    var session = ""
    static func format(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 {
            let number = String(format: n < 100_000 ? "%.1f" : "%.0f", Double(n)/1000)
            let compact = number.hasSuffix(".0") ? String(number.dropLast(2)) : number
            return compact.replacingOccurrences(of: ".", with: ",") + " тыс."
        }
        return String(format: "%.2f", Double(n)/1_000_000).replacingOccurrences(of: ".", with: ",") + " млн"
    }
    var line: String {
        "\(Self.format(tokens.input)) отправлено · \(Self.format(tokens.cached)) из кэша · \(Self.format(tokens.output)) получено · контекст \(context.map { "≈\($0)%" } ?? "—")"
    }
}

final class SessionReader {
    var offset: UInt64 = 0
    var pending = Data()
    var total = Tokens()
    var usage: Usage?
    var current = Usage()
    var hasTurn = false
    var turnHasUsage = false
    var isChild = false
    var lastSize: UInt64 = 0

    func consume(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { consume(obj) }
            pending.removeSubrange(...end)
        }
    }
    func consume(_ obj: [String: Any]) {
        guard let p = obj["payload"] as? [String: Any] else { return }
        if obj["type"] as? String == "session_meta" {
            current.project = (p["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
            current.session = p["id"] as? String ?? ""
            if let source = p["source"] as? [String: Any], source["subagent"] != nil { isChild = true }
            return
        }
        guard obj["type"] as? String == "event_msg" else { return }
        let stamp = obj["timestamp"] as? String ?? ""
        switch p["type"] as? String {
        case "task_started":
            current.tokens = Tokens(); current.running = true; hasTurn = true; turnHasUsage = false
        case "task_complete", "turn_aborted":
            current.running = false
            if hasTurn, turnHasUsage { current.timestamp = stamp; usage = current }
            hasTurn = false
        case "token_count":
            guard let info = p["info"] as? [String: Any], let raw = info["total_token_usage"] as? [String: Any] else { return }
            let next = Tokens(raw)
            // Totals make duplicate token events idempotent. A reset starts a new counter epoch.
            let delta = next.input < total.input || next.output < total.output ? next : next - total
            total = next
            guard delta != Tokens() else { return }
            if !hasTurn { current.tokens = Tokens(); hasTurn = true }
            current.tokens.add(delta); turnHasUsage = true
            if let last = info["last_token_usage"] as? [String: Any], let window = info["model_context_window"] as? Int, window > 0 {
                let used = last["total_tokens"] as? Int ?? ((last["input_tokens"] as? Int ?? 0) + (last["output_tokens"] as? Int ?? 0))
                current.context = min(100, max(0, Int((Double(used) / Double(window) * 100).rounded())))
            } else { current.context = nil }
            current.timestamp = stamp; usage = current
        default: break
        }
    }
    func read(_ url: URL) {
        guard let f = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? f.close() }
        guard let size = try? f.seekToEnd() else { return }
        if size < offset { offset = 0; pending = Data(); total = Tokens(); usage = nil; hasTurn = false }
        guard size > offset else { return }
        do {
            try f.seek(toOffset: offset)
            while let chunk = try f.read(upToCount: 262144), !chunk.isEmpty { offset += UInt64(chunk.count); consume(chunk) }
        } catch { return }
    }
}

final class UsageMonitor {
    let root: URL
    var readers: [URL: SessionReader] = [:]
    init(root: URL) { self.root = root }
    func poll() -> Usage? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(URL, Date, Int)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            candidates.append((url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0))
        }
        // Bootstrap recent sessions; thereafter discover new and modified sessions regardless of age.
        let initial = readers.isEmpty
        for (url, _, size) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(initial ? 12 : candidates.count) {
            if readers[url] == nil { readers[url] = SessionReader() }
            let reader = readers[url]!
            if reader.offset != UInt64(size) { reader.read(url) }
        }
        return readers.values.filter { !$0.isChild }.compactMap(\.usage).max { $0.timestamp < $1.timestamp }
    }
}
