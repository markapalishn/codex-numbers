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

enum TokenCountMode: String, CaseIterable {
    case all, outgoing
    static let defaultsKey = "tokenCountMode"
    static func load(from defaults: UserDefaults = .standard) -> TokenCountMode {
        TokenCountMode(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .all
    }
    var title: String { self == .all ? "Все" : "Исходящие" }
    func count(_ tokens: Tokens) -> Int { self == .all ? tokens.input + tokens.output : tokens.output }
}

struct Usage {
    var countMode: TokenCountMode = .all
    var tokens = Tokens()
    var isEstimate = false
    var remainingLimit: Int?
    var limitResetAt: Double?
    var limitWindowDuration: Double?
    var timestamp = ""
    var running = false
    var activeRequestIDs = Set<String>()
    var activeRequestCount: Int { running ? max(1, activeRequestIDs.count) : 0 }
    var requestCaption: String {
        if activeRequestCount > 1 {
            return "В работе: \(activeRequestCount)"
        }
        return "Запрос"
    }
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
    var requestTokens: Int { countMode.count(tokens) }
    var badgeUsage: Usage {
        var result = self
        if !running { result.tokens = Tokens() }
        return result
    }
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
        return "\(requestCaption): \(count) токенов · Остаток лимита: \(remainingLimit.map { "\($0)%" } ?? "—")"
    }
}

struct LimitSnapshot {
    var timestamp: String
    var windows: [(used: Double, resets: Double, duration: Double?)]
    init?(_ raw: [String: Any], timestamp: String) {
        guard raw["limit_id"] as? String == "codex" || raw["limit_id"] == nil else { return nil }
        self.timestamp = timestamp
        windows = ["primary", "secondary"].compactMap { key in
            guard let window = raw[key] as? [String: Any],
                  let used = window["used_percent"] as? Double,
                  let resets = window["resets_at"] as? Double,
                  used.isFinite, resets.isFinite else { return nil }
            let duration = (window["window_minutes"] as? Double).map { $0 * 60 }
            return (used, resets, duration)
        }
    }
    func remaining(now: Double = Date().timeIntervalSince1970) -> Int? {
        current(now: now)?.remaining
    }
    func current(now: Double = Date().timeIntervalSince1970) -> (remaining: Int, resets: Double, duration: Double?)? {
        // A passed reset needs fresh server data; don't invent a full allowance.
        guard !windows.isEmpty, windows.allSatisfy({ $0.resets > now }),
              let window = windows.max(by: { $0.used < $1.used }) else { return nil }
        return (Int(max(0, min(100, 100 - window.used)).rounded(.down)), window.resets, window.duration)
    }
}

struct TurnState {
    var id: String
    var root: String
    var usage: Usage
    var projectPath: String
    var lifecycleTimestamp = ""
    var requestText = ""
}

final class SessionReader {
    var offset: UInt64 = 0
    var pending = Data()
    var total = Tokens()
    var current = Usage()
    var isChild = false
    var limit: LimitSnapshot?
    var model = "Неизвестная модель"
    var projectPath = ""
    var turnID = ""
    var pendingRequestText = ""
    var states: [String: TurnState] = [:]
    var contexts: [String: (model: String, project: String, path: String)] = [:]
    var responses: [String: TokenSample] = [:]
    var legacy: [TokenSample] = []
    var modernTurns = Set<String>()
    var checkpoints: [String: Tokens] = [:]
    var usage: Usage? {
        guard let state = states.values.max(by: { $0.usage.timestamp < $1.usage.timestamp }) else { return nil }
        var value = state.usage
        let own = samples.filter { $0.localTurn == state.id }
        value.tokens = Tokens(); own.forEach { value.tokens.add($0.tokens) }
        value.isEstimate = own.contains { !$0.authoritative }
        return value
    }
    var samples: [TokenSample] {
        Array(responses.values) + legacy.filter { !modernTurns.contains($0.localTurn) }
    }
    private func ensureTurn(_ id: String, stamp: String) {
        guard states[id] == nil else { return }
        var value = current; value.timestamp = stamp
        states[id] = TurnState(id: id, root: id, usage: value, projectPath: projectPath)
        if !pendingRequestText.isEmpty { states[id]?.requestText = pendingRequestText; pendingRequestText = "" }
    }
    private func receiveRequestText(_ raw: String, explicitTurn: String? = nil) {
        let text = RequestText.clean(raw)
        guard !text.isEmpty else { return }
        let id = explicitTurn ?? turnID
        if !id.isEmpty, states[id] != nil, explicitTurn != nil || states[id]!.usage.running {
            if states[id]!.requestText.isEmpty { states[id]?.requestText = text }
        } else { pendingRequestText = text }
    }
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
        let stamp = obj["timestamp"] as? String ?? ""
        switch obj["type"] as? String {
        case "session_meta":
            projectPath = p["cwd"] as? String ?? ""
            current.project = projectPath.isEmpty ? "Codex" : URL(fileURLWithPath: projectPath).lastPathComponent
            current.session = p["id"] as? String ?? ""
            if let source = p["source"] as? [String: Any], source["subagent"] != nil { isChild = true }
        case "turn_context":
            model = p["model"] as? String ?? model
            turnID = p["turn_id"] as? String ?? turnID
            if let cwd = p["cwd"] as? String {
                projectPath = cwd; current.project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            contexts[turnID] = (model, current.project, projectPath)
            if states[turnID] != nil {
                states[turnID]?.usage.project = current.project
                states[turnID]?.projectPath = projectPath
            }
        case "response_item":
            if p["role"] as? String == "user", let parts = p["content"] as? [[String: Any]] {
                let text = parts.filter { $0["type"] as? String == "input_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                receiveRequestText(text)
            }
        case "token_usage_record":
            guard let response = p["response_id"] as? String, !response.isEmpty,
                  let turn = p["turn_id"] as? String, !turn.isEmpty,
                  let raw = p["usage"] as? [String: Any],
                  raw["input_tokens"] is NSNumber, raw["output_tokens"] is NSNumber,
                  let date = TokenSample.parseDate(stamp) else { return }
            let root = p["root_turn_id"] as? String ?? turn
            ensureTurn(turn, stamp: stamp)
            states[turn]?.root = root
            states[turn]?.usage.session = p["session_id"] as? String ?? current.session
            // Late records cannot reopen a completed turn or change another turn's counter.
            if stamp > states[turn]!.usage.timestamp { states[turn]?.usage.timestamp = stamp }
            let context = contexts[turn] ?? (model, current.project, projectPath)
            modernTurns.insert(turn)
            if responses[response] == nil {
                responses[response] = TokenSample(id: response, request: root, date: date,
                    project: context.project, projectPath: context.path, model: context.model,
                    tokens: Tokens(raw), localTurn: turn,
                    session: p["session_id"] as? String ?? current.session, authoritative: true)
            }
            if let checkpoint = p["turn_token_usage"] as? [String: Any] {
                let value = Tokens(checkpoint)
                if value.input + value.output >= (checkpoints[turn].map { $0.input + $0.output } ?? 0) { checkpoints[turn] = value }
            }
        case "event_msg":
            switch p["type"] as? String {
            case "user_message":
                if let text = p["message"] as? String { receiveRequestText(text, explicitTurn: p["turn_id"] as? String) }
            case "task_started":
                turnID = p["turn_id"] as? String ?? "\(current.session):\(stamp)"
                ensureTurn(turnID, stamp: stamp)
                if !pendingRequestText.isEmpty, states[turnID]!.requestText.isEmpty {
                    states[turnID]?.requestText = pendingRequestText
                    pendingRequestText = ""
                }
                states[turnID]?.lifecycleTimestamp = stamp
                states[turnID]?.usage.running = true
                states[turnID]?.usage.timestamp = stamp
            case "task_complete", "turn_aborted":
                let turn = p["turn_id"] as? String ?? turnID
                ensureTurn(turn, stamp: stamp)
                states[turn]?.lifecycleTimestamp = stamp
                states[turn]?.usage.running = false
                states[turn]?.usage.timestamp = stamp
            case "token_count":
                if let raw = p["rate_limits"] as? [String: Any], let snapshot = LimitSnapshot(raw, timestamp: stamp) { limit = snapshot }
                guard let info = p["info"] as? [String: Any], let raw = info["total_token_usage"] as? [String: Any] else { return }
                let next = Tokens(raw)
                let delta = next.input < total.input || next.output < total.output ? next : next - total
                total = next
                guard delta != Tokens(), let date = TokenSample.parseDate(stamp) else { return }
                if turnID.isEmpty { turnID = "\(current.session):\(stamp)" }
                ensureTurn(turnID, stamp: stamp)
                states[turnID]?.usage.timestamp = stamp
                legacy.append(TokenSample(id: "legacy|\(turnID)|\(stamp)|\(next.input)|\(next.output)",
                    request: turnID, date: date, project: current.project, projectPath: projectPath,
                    model: model, tokens: delta, localTurn: turnID, session: current.session))
            default: break
            }
        default: break
        }
    }
    func read(_ url: URL) {
        guard let f = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? f.close() }
        guard let size = try? f.seekToEnd() else { return }
        if size < offset {
            offset = 0; pending = Data(); total = Tokens(); current = Usage(); isChild = false
            states = [:]; contexts = [:]; responses = [:]; legacy = []; modernTurns = []
            checkpoints = [:]; pendingRequestText = ""; limit = nil; model = "Неизвестная модель"; projectPath = ""; turnID = ""
        }
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
    private(set) var polledSamples: [TokenSample] = []
    init(root: URL) { self.root = root }
    func mergedStates() -> [String: TurnState] {
        var states: [String: TurnState] = [:]
        for reader in readers.values {
            for (id, value) in reader.states {
                if let old = states[id] {
                    if value.lifecycleTimestamp > old.lifecycleTimestamp ||
                       (value.lifecycleTimestamp == old.lifecycleTimestamp && value.usage.timestamp > old.usage.timestamp) {
                        states[id] = value
                    }
                    states[id]?.usage.timestamp = max(old.usage.timestamp, value.usage.timestamp)
                    if value.root != id { states[id]?.root = value.root }
                    if states[id]!.requestText.isEmpty { states[id]?.requestText = old.requestText.isEmpty ? value.requestText : old.requestText }
                } else { states[id] = value }
            }
        }
        return states
    }
    func analyticsSamples() -> [TokenSample] {
        let states = mergedStates()
        let modern = readers.values.reduce(into: Set<String>()) { $0.formUnion($1.modernTurns) }
        var seen = Set<String>()
        // Deduplicate response IDs across files, forks and parent/child journal copies.
        return readers.values.flatMap(\.samples).sorted {
            let a = $0.model != "Неизвестная модель", b = $1.model != "Неизвестная модель"
            if a != b { return a }
            return $0.id < $1.id
        }.filter {
            ($0.authoritative || !modern.contains($0.localTurn)) && seen.insert($0.id).inserted
        }.map { sample in
            let parent = states[sample.request]
            return TokenSample(id: sample.id, request: sample.request, date: sample.date,
                project: parent?.usage.project ?? sample.project, projectPath: parent?.projectPath ?? sample.projectPath,
                model: sample.model, tokens: sample.tokens, localTurn: sample.localTurn,
                session: sample.session, authoritative: sample.authoritative, requestText: parent?.requestText ?? "")
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    func selectedUsage(now: Date = Date(), samples: [TokenSample]? = nil) -> Usage? {
        let states = mergedStates()
        // Only the last turn in each session can remain live; a newer turn supersedes it.
        let sessionLatest = Dictionary(grouping: states.values, by: { $0.usage.session }).values.compactMap {
            $0.max { $0.usage.timestamp < $1.usage.timestamp }
        }
        // Old journals can end with an unmatched start after a crash. Keep their
        // history, but do not revive a day-old silent turn as current work.
        let activeRoots = Set(sessionLatest.filter {
            $0.usage.running && (TokenSample.parseDate($0.usage.timestamp).map { now.timeIntervalSince($0) < 86_400 } ?? false)
        }.map(\.root))
        let candidates = states.values.filter { activeRoots.isEmpty || activeRoots.contains($0.root) }
        guard let latest = candidates.max(by: { $0.usage.timestamp < $1.usage.timestamp }) else { return nil }
        var value = states[latest.root]?.usage ?? latest.usage
        value.timestamp = latest.usage.timestamp
        value.running = !activeRoots.isEmpty
        value.activeRequestIDs = activeRoots
        let samples = (samples ?? analyticsSamples()).filter {
            activeRoots.isEmpty ? $0.request == latest.root : activeRoots.contains($0.request)
        }
        value.tokens = Tokens(); samples.forEach { value.tokens.add($0.tokens) }
        value.isEstimate = samples.contains { !$0.authoritative }
        if let limit = readers.values.compactMap(\.limit).max(by: { $0.timestamp < $1.timestamp })?.current(now: now.timeIntervalSince1970) {
            value.remainingLimit = limit.remaining
            value.limitResetAt = limit.resets
            value.limitWindowDuration = limit.duration
        } else {
            value.remainingLimit = nil
            value.limitResetAt = nil
            value.limitWindowDuration = nil
        }
        return value
    }
    func poll() -> Usage? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(URL, Date, Int)] = []
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            candidates.append((url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0))
        }
        let initial = readers.isEmpty
        var changed = initial
        for (url, _, size) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(initial ? 12 : candidates.count) {
            if readers[url] == nil { readers[url] = SessionReader(); changed = true }
            let reader = readers[url]!
            if reader.offset != UInt64(size) { reader.read(url); changed = true }
        }
        // Historical sorting/deduplication is expensive; do it once per change,
        // while still reevaluating live requests and limit expiry every poll.
        if changed { polledSamples = analyticsSamples() }
        return selectedUsage(samples: polledSamples)
    }
}
