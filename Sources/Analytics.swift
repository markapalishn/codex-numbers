import Foundation

struct TokenSample {
    let id: String
    let request: String
    let date: Date
    let project: String
    let projectPath: String
    let model: String
    let tokens: Tokens
    var localTurn: String = ""
    var session: String = ""
    var authoritative: Bool = false
    var requestText: String = ""
    var count: Int { tokens.input + tokens.output }
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let regular = ISO8601DateFormatter()
    static func parseDate(_ value: String) -> Date? { fractional.date(from: value) ?? regular.date(from: value) }
}

struct AnalyticsGroup {
    let key: String
    let title: String
    let total: Int
    let requests: Int
    let isEstimate: Bool
}
struct AnalyticsRequest {
    let id: String
    let date: Date
    let project: String
    let models: String
    let text: String
    var title: String { text.isEmpty ? "Запрос без текста" : RequestText.title(text) }
    let total: Int
    let isEstimate: Bool
}
struct AnalyticsBucket {
    let date: Date
    let total: Int
}
struct AnalyticsSummary {
    let samples: [TokenSample]
    let start: Date
    let end: Date
    let hourly: Bool
    var isEstimate: Bool { samples.contains { !$0.authoritative } }
    var total: Int { samples.reduce(0) { $0 + $1.count } }
    var input: Int { samples.reduce(0) { $0 + $1.tokens.input } }
    var cached: Int { samples.reduce(0) { $0 + $1.tokens.cached } }
    var output: Int { samples.reduce(0) { $0 + $1.tokens.output } }
    var requestCount: Int { Set(samples.map(\.request)).count }
    var cachePercent: Int { input == 0 ? 0 : Int((100 * Double(cached) / Double(input)).rounded()) }
    init(samples: [TokenSample], period: Int, project: String? = nil, model: String? = nil, now: Date = Date(), calendar: Calendar = .current) {
        end = now
        hourly = period == 0
        let today = calendar.startOfDay(for: now)
        switch period {
        case 0: start = today
        case 1: start = calendar.date(byAdding: .day, value: -6, to: today)!
        case 2: start = calendar.date(byAdding: .day, value: -29, to: today)!
        default: start = calendar.startOfDay(for: samples.map(\.date).min() ?? now)
        }
        let lowerBound = start
        self.samples = samples.filter { $0.date >= lowerBound && $0.date <= now && (project == nil || $0.projectPath == project) && (model == nil || $0.model == model) }
    }
    func groups(byModel: Bool) -> [AnalyticsGroup] {
        Dictionary(grouping: samples, by: { byModel ? $0.model : $0.projectPath }).map { key, values in
            AnalyticsGroup(key: key, title: byModel ? key : (values.first?.project ?? key), total: values.reduce(0) { $0 + $1.count }, requests: Set(values.map(\.request)).count, isEstimate: values.contains { !$0.authoritative })
        }.sorted { $0.total == $1.total ? $0.key < $1.key : $0.total > $1.total }
    }
    var requests: [AnalyticsRequest] {
        Dictionary(grouping: samples, by: \.request).map { key, values in
            AnalyticsRequest(id: key, date: values.map(\.date).max()!, project: values.first!.project,
                models: Set(values.map(\.model)).sorted().joined(separator: ", "), text: values.first(where: { !$0.requestText.isEmpty })?.requestText ?? "", total: values.reduce(0) { $0 + $1.count }, isEstimate: values.contains { !$0.authoritative })
        }.sorted { $0.date > $1.date }
    }
    func buckets(calendar: Calendar = .current) -> [AnalyticsBucket] {
        let component: Calendar.Component = hourly ? .hour : .day
        let grouped = Dictionary(grouping: samples) { calendar.dateInterval(of: component, for: $0.date)!.start }
        var result: [AnalyticsBucket] = []
        var date = start
        while date <= end {
            result.append(AnalyticsBucket(date: date, total: grouped[date, default: []].reduce(0) { $0 + $1.count }))
            guard let next = calendar.date(byAdding: component, value: 1, to: date) else { break }
            date = next
        }
        return result
    }
}

// Titles are local excerpts, never generated with a model or sent over the network.
enum RequestText {
    static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrefixes = ["# AGENTS.md instructions", "<environment_context>", "<permissions instructions>", "<collaboration_mode>", "<app-context>", "<system-reminder>", "<recommended_plugins>"]
        if systemPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return "" }
        return trimmed
    }
    static func title(_ value: String) -> String {
        let compact = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return compact.count > 100 ? String(compact.prefix(99)) + "…" : compact
    }
}
