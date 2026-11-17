import Foundation

// MARK: - What a call used

/// What one model used in a call, and what Claude Code estimated that cost.
struct UsageModelTotals: Codable, Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var cost = 0.0

    /// What the footer counts: the tokens read fresh, written and cached. Cache reads are kept apart, as they dominate a long session.
    var tokens: Int { input + output + cacheWrite }

    var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 && cost == 0 }

    /// This minus an earlier cumulative total of the same model; a total that went down means the count started over, so it stands as it is.
    func since(_ base: UsageModelTotals) -> UsageModelTotals {
        guard input >= base.input, output >= base.output, cacheRead >= base.cacheRead, cacheWrite >= base.cacheWrite, cost >= base.cost else { return self }
        return UsageModelTotals(input: input - base.input, output: output - base.output, cacheRead: cacheRead - base.cacheRead,
                                cacheWrite: cacheWrite - base.cacheWrite, cost: cost - base.cost)
    }

    static func + (lhs: UsageModelTotals, rhs: UsageModelTotals) -> UsageModelTotals {
        UsageModelTotals(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
                         cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cost: lhs.cost + rhs.cost)
    }
}

/// What a call used, per model, as Claude Code reported it: the main loop, subagents and compaction together.
struct UsageTotals: Codable, Equatable, Sendable {
    var models: [String: UsageModelTotals] = [:]
    /// The cost Claude Code reported for the whole call; nil when it reported none.
    var reportedCost: Double?
    var durationMs: Int?
    var turns: Int?

    var isEmpty: Bool { models.values.allSatisfy(\.isEmpty) && reportedCost == nil }

    var tokens: Int { models.values.reduce(0) { $0 + $1.tokens } }
    var cacheReadTokens: Int { models.values.reduce(0) { $0 + $1.cacheRead } }

    /// The call's cost: what Claude Code reported for it, else the models' costs added up, nil when it said nothing about cost.
    var cost: Double? {
        if let reportedCost { return reportedCost }
        let costs = models.values.map(\.cost)
        return costs.contains { $0 > 0 } ? costs.reduce(0, +) : nil
    }

    /// The model that did most of the work: the one with the most output, else the most tokens.
    var mainModel: String? {
        models.max { lhs, rhs in
            (lhs.value.output, lhs.value.tokens, rhs.key) < (rhs.value.output, rhs.value.tokens, lhs.key)
        }?.key
    }

    // MARK: Reading

    /// The numbers in a result message: Claude Code's own `result` line (`total_cost_usd`, `modelUsage`, `usage`, `duration_ms`, `num_turns`),
    /// which the agent sidecar forwards in the same shape. `modelUsage` is the field for tokens and cost; the main loop's `usage` stands in
    /// for it when it is missing. Nil when the message holds no usage.
    static func parse(_ object: [String: Any]) -> UsageTotals? {
        func number(_ value: Any?) -> Double? { (value as? NSNumber).map(\.doubleValue) }
        func count(_ value: Any?) -> Int { number(value).map { Int($0.rounded()) } ?? 0 }
        var totals = UsageTotals()
        for (name, entry) in object["modelUsage"] as? [String: Any] ?? [:] {
            guard let entry = entry as? [String: Any] else { continue }
            let model = UsageModelTotals(input: count(entry["inputTokens"]), output: count(entry["outputTokens"]),
                                         cacheRead: count(entry["cacheReadInputTokens"]), cacheWrite: count(entry["cacheCreationInputTokens"]),
                                         cost: number(entry["costUSD"]) ?? 0)
            if !model.isEmpty { totals.models[name] = model }
        }
        totals.reportedCost = number(object["total_cost_usd"])
        if totals.models.isEmpty, let usage = object["usage"] as? [String: Any] {
            let model = UsageModelTotals(input: count(usage["input_tokens"]), output: count(usage["output_tokens"]),
                                         cacheRead: count(usage["cache_read_input_tokens"]), cacheWrite: count(usage["cache_creation_input_tokens"]),
                                         cost: totals.reportedCost ?? 0)
            if !model.isEmpty { totals.models[UsageTotals.unknownModel] = model }
        }
        totals.durationMs = number(object["duration_ms"]).map { Int($0) }
        totals.turns = number(object["num_turns"]).map { Int($0) }
        return totals.models.isEmpty && totals.reportedCost == nil ? nil : totals
    }

    static let unknownModel = "unknown"

    // MARK: Measuring

    /// This call's own share of a cumulative total: Claude Code counts across the turns of one session, so a turn is the difference from
    /// the total before it. A model or cost that went down means the count started over, and stands as it is.
    func since(_ base: UsageTotals?) -> UsageTotals {
        guard let base else { return self }
        var share = self
        share.models = [:]
        for (name, total) in models {
            let own = total.since(base.models[name] ?? UsageModelTotals())
            if !own.isEmpty { share.models[name] = own }
        }
        if let reportedCost {
            let before = base.reportedCost ?? 0
            share.reportedCost = reportedCost >= before ? reportedCost - before : reportedCost
        }
        return share
    }

    /// What a turn of an agent used, from the total Claude Code reported after it and the one the same session had reached before.
    /// `counted` is false when that earlier total is not known (a resumed session the app never measured): the total becomes the starting
    /// point for the next turn and nothing is charged to this one.
    static func measure(reported: UsageTotals, known: UsageTotals?, startsFresh: Bool) -> (share: UsageTotals, counted: Bool) {
        if let known { return (reported.since(known), true) }
        if startsFresh { return (reported, true) }
        var empty = UsageTotals()
        empty.durationMs = reported.durationMs
        empty.turns = reported.turns
        return (empty, false)
    }
}

// MARK: - Reporting from anywhere

/// Where a call made off the main actor reports what it used. The app connects it to the usage store when it starts; until then,
/// and in tests, a report goes nowhere.
enum UsageReport {
    typealias Sink = @Sendable (UsageTotals, UsageKind, String?, Date) -> Void

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: Sink?

        func set(_ sink: Sink?) {
            lock.lock()
            self.sink = sink
            lock.unlock()
        }

        func get() -> Sink? {
            lock.lock()
            defer { lock.unlock() }
            return sink
        }
    }

    private static let holder = Holder()

    static func connect(_ sink: Sink?) { holder.set(sink) }

    static func note(call totals: UsageTotals?, kind: UsageKind, name: String? = nil, now: Date = Date()) {
        guard let totals, !totals.isEmpty else { return }
        holder.get()?(totals, kind, name, now)
    }

    /// A call that reported tokens but no cost, such as one made with an API key.
    static func note(tokens input: Int, output: Int, model: String, kind: UsageKind, now: Date = Date()) {
        note(call: UsageTotals(models: [model: UsageModelTotals(input: input, output: output)]), kind: kind, now: now)
    }
}

// MARK: - The log

enum UsageKind: String, Codable, CaseIterable, Sendable {
    case main, assistant, pullRequest, topic, set, routine, automation, summary, review, analysis, other

    var title: String {
        switch self {
        case .main: "Main"
        case .assistant: "Assistant"
        case .pullRequest: "Pull request agent"
        case .topic: "Topic agent"
        case .set: "Pull request set"
        case .routine: "Routine"
        case .automation: "Automation"
        case .summary: "Meeting summary"
        case .review: "Pull request summary"
        case .analysis: "Routine analysis"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .main: "chevron.left.forwardslash.chevron.right"
        case .assistant: "person.crop.circle"
        case .pullRequest, .set: "arrow.triangle.branch"
        case .topic: "bubble.left"
        case .routine: "clock.arrow.circlepath"
        case .automation: "bolt"
        case .summary: "waveform"
        case .review: "text.magnifyingglass"
        case .analysis: "wand.and.stars"
        case .other: "sparkles"
        }
    }

    /// Runs of an agent that works a session, which the usage page can open.
    var isAgent: Bool { [.main, .assistant, .pullRequest, .topic, .set, .routine, .automation].contains(self) }
}

/// One call to Claude: when, by whom, and what it used. The prompt and the answer are never kept.
struct UsageRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var date: Date
    var session: String?
    var kind: UsageKind
    /// The agent key, the routine's or automation's id; nil for a call without one.
    var key: String?
    /// What the call is shown as: the agent's, routine's or automation's name.
    var name: String?
    var workspace: String?
    /// This call's own share.
    var totals: UsageTotals
    /// The session's running total as Claude Code reported it, which the session's next turn is measured against.
    var cumulative: UsageTotals?
    /// False when the share could not be told: the call stands in the log as a starting point only.
    var counted = true
    var failed = false

    var cost: Double? { counted ? totals.cost : nil }
    var tokens: Int { counted ? totals.tokens : 0 }
    var mainModel: String? { totals.mainModel }

    /// The key the Agent page opens this call's agent by; nil for a call that no agent made.
    var agentKey: String? {
        guard kind.isAgent, let key else { return nil }
        return kind == .routine || kind == .automation ? Routines.prefix + key : key
    }
}

/// The usage log: one JSON line per call in a file, kept for `retentionDays` days.
struct UsageLog {
    static let retentionDays = 180

    let url: URL

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func append(_ record: UsageRecord) {
        guard var line = try? Self.encoder.encode(record) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The records within the retention window, oldest first. A line that cannot be read or is too old is dropped, and the file is
    /// rewritten without it.
    func load(now: Date, calendar: Calendar = .current) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let all = lines.compactMap { try? Self.decoder.decode(UsageRecord.self, from: Data($0)) }
        let kept = Usage.pruned(all, now: now, calendar: calendar).sorted { $0.date < $1.date }
        if kept.count != lines.count { rewrite(kept) }
        return kept
    }

    /// The same records as `load`, without rewriting the file, for a process that only reads it.
    func read(now: Date, calendar: Calendar = .current) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let all = data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { try? Self.decoder.decode(UsageRecord.self, from: Data($0)) }
        return Usage.pruned(all, now: now, calendar: calendar).sorted { $0.date < $1.date }
    }

    private func rewrite(_ records: [UsageRecord]) {
        var data = Data()
        for record in records {
            guard let line = try? Self.encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Showing it

enum UsageCurrency: String, CaseIterable, Identifiable {
    case usd = "USD", eur = "EUR"

    var id: String { rawValue }
    var symbol: String { self == .usd ? "$" : "\u{20AC}" }
}

/// How money is shown: Claude Code reports dollars, and euros use the rate the user entered.
struct UsageDisplay: Equatable {
    static let currencyKey = "usageCurrency"
    static let rateKey = "usageEurPerUsd"

    var currency = UsageCurrency.usd
    /// Euros for one dollar; euros are shown only when this is above zero.
    var eurPerUsd = 0.0

    static func current(defaults: UserDefaults = .standard) -> UsageDisplay {
        UsageDisplay(currency: defaults.string(forKey: currencyKey).flatMap(UsageCurrency.init(rawValue:)) ?? .usd,
                     eurPerUsd: defaults.double(forKey: rateKey))
    }

    var shown: UsageCurrency { currency == .eur && eurPerUsd > 0 ? .eur : .usd }

    func money(_ usd: Double) -> String {
        let value = shown == .eur ? usd * eurPerUsd : usd
        let symbol = shown.symbol
        if value <= 0 { return symbol + "0.00" }
        if value < 0.005 { return "<" + symbol + "0.01" }
        return symbol + String(format: value < 100 ? "%.2f" : "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

enum UsageFormat {
    /// 950, 41k, 1.3M: tokens as the footer and the page show them.
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<10_000: return trimmed(Double(count) / 1_000) + "k"
        case ..<1_000_000: return "\(Int((Double(count) / 1_000).rounded()))k"
        case ..<10_000_000: return trimmed(Double(count) / 1_000_000) + "M"
        default: return "\(Int((Double(count) / 1_000_000).rounded()))M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// `claude-sonnet-5-5` as Sonnet 5.5: the app's own names first, then the id's family and version, else the id as it is.
    static func modelName(_ id: String) -> String {
        let known = AgentLogic.modelName(id)
        if known != id || !id.hasPrefix("claude-") { return known }
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        let family = parts.filter { $0.allSatisfy(\.isLetter) }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }
        guard family.count == 1, let name = family.first else { return id }
        return name.capitalized + (version.isEmpty ? "" : " " + version.joined(separator: "."))
    }

    /// The parts a finished turn's line adds: how many tokens, and what Claude Code estimated the turn cost.
    static func footer(_ totals: UsageTotals?, display: UsageDisplay = .current()) -> [String] {
        guard let totals else { return [] }
        var parts: [String] = []
        if totals.tokens > 0 { parts.append("\(tokens(totals.tokens)) tokens") }
        if let cost = totals.cost { parts.append(display.money(cost)) }
        return parts
    }
}

// MARK: - Adding it up

enum UsageRange: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    /// The first moment of the range: the start of the day `days - 1` days back.
    func start(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

enum UsageGroup: String, CaseIterable, Identifiable {
    case workspace, agent, routine, automation, model

    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspace: "Workspace"
        case .agent: "Agent"
        case .routine: "Routine"
        case .automation: "Automation"
        case .model: "Model"
        }
    }
}

struct UsageSummary: Equatable {
    var cost = 0.0
    var tokens = 0
    var cacheReadTokens = 0
    var runs = 0
    /// Runs Claude Code reported no cost for, which the cost leaves out.
    var unpriced = 0
}

struct UsageRow: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: UsageKind?
    var cost = 0.0
    var tokens = 0
    var runs = 0
    var unpriced = 0
    /// The models the runs used, by cost, so an expensive default shows.
    var models: [String] = []
}

struct UsageDay: Identifiable, Equatable {
    var date: Date
    var cost = 0.0
    var byWorkspace: [String: Double] = [:]
    var byModel: [String: Double] = [:]

    var id: Date { date }
}

/// A saving the log suggests: a model used where a smaller one would probably do.
struct UsageIdea: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
}

enum Usage {
    static let noWorkspace = "No workspace"

    static func pruned(_ records: [UsageRecord], now: Date, days: Int = UsageLog.retentionDays, calendar: Calendar = .current) -> [UsageRecord] {
        let limit = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? .distantPast
        return records.filter { $0.date >= limit }
    }

    static func records(_ all: [UsageRecord], in range: UsageRange, now: Date, calendar: Calendar = .current) -> [UsageRecord] {
        let start = range.start(now: now, calendar: calendar)
        return all.filter { $0.date >= start && $0.date <= now.addingTimeInterval(60) }
    }

    static func summary(_ records: [UsageRecord]) -> UsageSummary {
        var summary = UsageSummary()
        for record in records where record.counted {
            summary.runs += 1
            summary.tokens += record.tokens
            summary.cacheReadTokens += record.totals.cacheReadTokens
            if let cost = record.cost { summary.cost += cost } else { summary.unpriced += 1 }
        }
        return summary
    }

    /// Every day of the range, empty ones included, with the day's cost by workspace and by model.
    static func days(_ records: [UsageRecord], range: UsageRange, now: Date, calendar: Calendar = .current) -> [UsageDay] {
        let first = range.start(now: now, calendar: calendar)
        var days = (0..<range.days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: first).map { UsageDay(date: $0) }
        }
        for record in records where record.counted {
            guard let index = days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: record.date) }) else { continue }
            let cost = record.cost ?? 0
            days[index].cost += cost
            days[index].byWorkspace[record.workspace ?? noWorkspace, default: 0] += cost
            for (model, totals) in record.totals.models { days[index].byModel[model, default: 0] += totals.cost }
        }
        return days
    }

    /// The costs grouped, dearest first. Routines and automations list only their own kind; the others take every call.
    static func rows(_ records: [UsageRecord], by group: UsageGroup) -> [UsageRow] {
        var rows: [String: UsageRow] = [:]
        var modelCosts: [String: [String: Double]] = [:]
        func add(_ id: String, name: String, kind: UsageKind?, cost: Double?, tokens: Int, models: [String: UsageModelTotals]) {
            var row = rows[id] ?? UsageRow(id: id, name: name, kind: kind)
            row.runs += 1
            row.tokens += tokens
            if let cost { row.cost += cost } else { row.unpriced += 1 }
            rows[id] = row
            for (model, totals) in models { modelCosts[id, default: [:]][model, default: 0] += totals.cost }
        }
        for record in records where record.counted {
            switch group {
            case .workspace:
                let name = record.workspace ?? noWorkspace
                add("workspace:" + name, name: name, kind: nil, cost: record.cost, tokens: record.tokens, models: record.totals.models)
            case .agent:
                let name = record.name ?? record.kind.title
                add("agent:" + record.kind.rawValue + ":" + (record.key ?? name), name: name, kind: record.kind,
                    cost: record.cost, tokens: record.tokens, models: record.totals.models)
            case .routine, .automation:
                guard record.kind == (group == .routine ? .routine : .automation) else { continue }
                let name = record.name ?? record.kind.title
                add(group.rawValue + ":" + (record.key ?? name), name: name, kind: record.kind,
                    cost: record.cost, tokens: record.tokens, models: record.totals.models)
            case .model:
                for (model, totals) in record.totals.models {
                    add("model:" + model, name: UsageFormat.modelName(model), kind: nil, cost: totals.cost, tokens: totals.tokens,
                        models: [model: totals])
                }
            }
        }
        return rows.values.map { row in
            var row = row
            row.models = (modelCosts[row.id] ?? [:]).sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { UsageFormat.modelName($0.key) }
            return row
        }.sorted { ($0.cost, $0.name) > ($1.cost, $1.name) }
    }

    /// The calls that cost most, dearest first.
    static func expensive(_ records: [UsageRecord], limit: Int = 8) -> [UsageRecord] {
        Array(records.filter { $0.counted && $0.cost != nil }.sorted { ($0.cost ?? 0) > ($1.cost ?? 0) }.prefix(limit))
    }

    /// The most cost a model can have for its calls to count as short: a few turns that wrote little.
    static let shortTurns = 3
    static let shortOutput = 2_500
    static let shortRunsToSuggest = 3

    /// Opus doing short jobs over and over: an agent, routine or automation whose calls were mostly a few turns with little output.
    static func ideas(_ records: [UsageRecord]) -> [UsageIdea] {
        var groups: [String: (name: String, runs: Int, cost: Double)] = [:]
        for record in records where record.counted {
            guard let model = record.mainModel, model.lowercased().contains("opus"), let main = record.totals.models[model],
                  (record.totals.turns ?? 1) <= shortTurns, main.output <= shortOutput else { continue }
            let id = record.kind.rawValue + ":" + (record.key ?? record.name ?? "")
            var group = groups[id] ?? (name: record.name ?? record.kind.title, runs: 0, cost: 0)
            group.runs += 1
            group.cost += record.cost ?? 0
            groups[id] = group
        }
        return groups.filter { $0.value.runs >= shortRunsToSuggest }.sorted { ($0.value.cost, $0.key) > ($1.value.cost, $1.key) }.map { id, group in
            UsageIdea(id: id, title: "\(group.name) ran \(group.runs) short jobs on Opus",
                      detail: "A few turns each, with little written. A smaller model would probably do, and it costs a fraction of Opus.")
        }
    }
}

// MARK: - Limits

/// The warnings the user asked for: one run that cost more than a limit, and a day that went over a budget. Both are off until set.
struct UsageLimits: Equatable {
    static let perRunKey = "usagePerRunAlert"
    static let dailyKey = "usageDailyBudget"
    static let budgetDayKey = "usageBudgetNotifiedDay"

    /// In dollars; nil is off.
    var perRun: Double?
    var dailyBudget: Double?

    static func stored(defaults: UserDefaults = .standard) -> UsageLimits {
        func limit(_ key: String) -> Double? { defaults.double(forKey: key) > 0 ? defaults.double(forKey: key) : nil }
        return UsageLimits(perRun: limit(perRunKey), dailyBudget: limit(dailyKey))
    }
}

enum UsageAlerts {
    struct Alert: Equatable {
        let title: String
        let body: String
        /// `daily` alerts are sent once a day; the notification is replaced by a later one of the same identifier.
        let identifier: String
        var isDaily = false
    }

    /// What to tell the user about a call that was just recorded: a run over the limit, a day over its budget (once a day).
    static func alerts(for record: UsageRecord, todayBefore: Double, limits: UsageLimits, display: UsageDisplay,
                       dayKey: String, notifiedDay: String?) -> [Alert] {
        guard record.counted, let cost = record.cost else { return [] }
        var alerts: [Alert] = []
        let name = record.name ?? record.kind.title
        if let limit = limits.perRun, cost >= limit {
            alerts.append(Alert(title: "\(name) used \(display.money(cost))",
                                body: "One run went over your limit of \(display.money(limit)).", identifier: "usage-run-" + record.id))
        }
        if let budget = limits.dailyBudget, todayBefore < budget, todayBefore + cost >= budget, notifiedDay != dayKey {
            alerts.append(Alert(title: "Today's usage passed \(display.money(budget))",
                                body: "\(display.money(todayBefore + cost)) so far today, estimated by Claude Code.", identifier: "usage-day-" + dayKey, isDaily: true))
        }
        return alerts
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - The plan's limits

/// How full the Claude plan's windows are, from the same data as Claude Code's `/usage` screen.
struct UsagePlan: Equatable {
    struct Window: Equatable, Identifiable {
        var id: String
        var title: String
        /// 0 to 100.
        var percent: Double
        var resets: Date?
    }

    struct Extra: Equatable {
        var percent: Double?
        /// In the plan's currency; Claude Code reports them in hundredths of it.
        var used: Double?
        var limit: Double?
        var currency: String?
    }

    var subscription: String?
    var windows: [Window] = []
    var extra: Extra?

    /// The sidecar's `plan` line: `{subscription, limits: {five_hour, seven_day, ..., model_scoped, extra_usage}}`.
    static func parse(_ object: [String: Any]) -> UsagePlan? {
        guard let limits = object["limits"] as? [String: Any] else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { parser.date(from: $0) ?? plain.date(from: $0) } }
        func window(_ id: String, _ title: String, _ source: Any?) -> Window? {
            guard let source = source as? [String: Any], let percent = (source["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(id: id, title: title, percent: percent, resets: date(source["resets_at"]))
        }
        var plan = UsagePlan(subscription: object["subscription"] as? String)
        let named: [(String, String)] = [("five_hour", "5-hour limit"), ("seven_day", "Weekly \u{00B7} all models"),
                                         ("seven_day_opus", "Weekly \u{00B7} Opus"), ("seven_day_sonnet", "Weekly \u{00B7} Sonnet")]
        plan.windows = named.compactMap { window($0.0, $0.1, limits[$0.0]) }
        for scoped in limits["model_scoped"] as? [[String: Any]] ?? [] {
            if let name = scoped["display_name"] as? String, let found = window("model:" + name, "Weekly \u{00B7} " + name, scoped) { plan.windows.append(found) }
        }
        if let extra = limits["extra_usage"] as? [String: Any] {
            func amount(_ key: String) -> Double? { (extra[key] as? NSNumber).map { $0.doubleValue / 100 } }
            plan.extra = Extra(percent: (extra["utilization"] as? NSNumber)?.doubleValue, used: amount("used_credits"), limit: amount("monthly_limit"),
                               currency: extra["currency"] as? String)
        }
        return plan.windows.isEmpty && plan.extra == nil ? nil : plan
    }

    /// "resets in 4h 55m", "resets in 2d 19h".
    static func resetText(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(max(1, minutes))m"
    }
}

/// What asking Claude Code for the plan's limits gave: the limits, that they do not apply (an API key, say), or why it failed.
enum UsagePlanOutcome: Equatable {
    case plan(UsagePlan)
    case notApplicable
    case failed(String)

    /// The helper's last line: `{"plan": {...}}`, `{"plan": null}` or `{"error": "..."}`.
    static func parse(_ output: String) -> UsagePlanOutcome {
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Claude Code gave no answer.")
        }
        if let error = object["error"] as? String { return .failed(error) }
        guard let plan = object["plan"] as? [String: Any] else { return .notApplicable }
        return UsagePlan.parse(plan).map { .plan($0) } ?? .notApplicable
    }
}
