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
    var remainingLimit: Int?
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
    var requestTokens: Int { tokens.input + tokens.output }
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        return formatter
    }()
    static func exact(_ value: Int) -> String { integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)" }
    var line: String {
        let count = Self.exact(requestTokens)
        return "Запрос: \(count) токенов · Остаток лимита: \(remainingLimit.map { "\($0)%" } ?? "—")"
    }
}

struct LimitSnapshot {
    var timestamp: String
    var windows: [(used: Double, resets: Double)]
    init?(_ raw: [String: Any], timestamp: String) {
        guard raw["limit_id"] as? String == "codex" || raw["limit_id"] == nil else { return nil }
        self.timestamp = timestamp
        windows = ["primary", "secondary"].compactMap { key in
            guard let window = raw[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let resets = window["resets_at"] as? Double,
                  used.isFinite, resets.isFinite else { return nil }
            return (used, resets)
        }
    }
    func remaining(now: Double = Date().timeIntervalSince1970) -> Int? {
        // A passed reset needs fresh server data; don't invent a full allowance.
        guard !windows.isEmpty, windows.allSatisfy({ $0.resets > now }) else { return nil }
        return windows.map { Int(max(0, min(100, 100 - $0.used)).rounded(.down)) }.min()
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
    var limit: LimitSnapshot?
    var samples: [TokenSample] = []
    var model = "Неизвестная модель"
    var projectPath = ""
    var turnID = ""


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
            projectPath = p["cwd"] as? String ?? ""
            current.project = (p["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
            current.session = p["id"] as? String ?? ""
            if let source = p["source"] as? [String: Any], source["subagent"] != nil { isChild = true }
            return
        }
        if obj["type"] as? String == "turn_context" {
            model = p["model"] as? String ?? model
            turnID = p["turn_id"] as? String ?? turnID
            if let cwd = p["cwd"] as? String {
                projectPath = cwd
                current.project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            return
        }
        guard obj["type"] as? String == "event_msg" else { return }
        let stamp = obj["timestamp"] as? String ?? ""
        switch p["type"] as? String {
        case "task_started":
            turnID = p["turn_id"] as? String ?? "\(current.session):\(stamp)"
            current.tokens = Tokens(); current.running = true; hasTurn = true; turnHasUsage = false
        case "task_complete", "turn_aborted":
            current.running = false
            if hasTurn, turnHasUsage { current.timestamp = stamp; usage = current }
            hasTurn = false
        case "token_count":
            if let raw = p["rate_limits"] as? [String: Any], let snapshot = LimitSnapshot(raw, timestamp: stamp) { limit = snapshot }
            guard let info = p["info"] as? [String: Any], let raw = info["total_token_usage"] as? [String: Any] else { return }
            let next = Tokens(raw)
            // Totals make duplicate token events idempotent. A reset starts a new counter epoch.
            let delta = next.input < total.input || next.output < total.output ? next : next - total
            total = next
            guard delta != Tokens() else { return }
            if !hasTurn { current.tokens = Tokens(); hasTurn = true }
            current.tokens.add(delta); turnHasUsage = true
            if let date = TokenSample.parseDate(stamp) {
                let request = turnID.isEmpty ? "\(current.session):\(stamp)" : turnID
                samples.append(TokenSample(id: "\(request)|\(stamp)|\(next.input)|\(next.output)",
                    request: request, date: date, project: current.project,
                    projectPath: projectPath, model: model, tokens: delta))
            }
            current.timestamp = stamp; usage = current
        default: break
        }
    }
    func read(_ url: URL) {
        guard let f = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? f.close() }
        guard let size = try? f.seekToEnd() else { return }
        if size < offset { offset = 0; pending = Data(); total = Tokens(); usage = nil; hasTurn = false; turnHasUsage = false; samples = []; limit = nil; model = "Неизвестная модель"; turnID = "" }
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
    func analyticsSamples() -> [TokenSample] {
        var seen = Set<String>()
        return readers.values.filter { !$0.isChild }.flatMap(\.samples)
            .filter { seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
    }
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
        var latest = readers.values.filter { !$0.isChild }.compactMap(\.usage).max { $0.timestamp < $1.timestamp }
        latest?.remainingLimit = readers.values.compactMap(\.limit).max { $0.timestamp < $1.timestamp }?.remaining()
        return latest
    }
}
