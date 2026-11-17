import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: 2026, month: month, day: dayOfMonth, hour: hour))!
}

private func model(input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, cost: Double = 0) -> UsageModelTotals {
    UsageModelTotals(input: input, output: output, cacheRead: read, cacheWrite: write, cost: cost)
}

private func record(_ id: String, at date: Date, kind: UsageKind = .assistant, key: String? = nil, name: String? = nil, workspace: String? = "alpha",
                    models: [String: UsageModelTotals], turns: Int? = 2, cost: Double? = nil, counted: Bool = true) -> UsageRecord {
    var totals = UsageTotals(models: models)
    totals.reportedCost = cost
    totals.turns = turns
    return UsageRecord(id: id, date: date, session: "s-" + id, kind: kind, key: key, name: name, workspace: workspace, totals: totals, counted: counted)
}

private func temporaryLog() -> UsageLog {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-" + UUID().uuidString, isDirectory: true)
    return UsageLog(url: folder.appendingPathComponent("usage.jsonl"))
}

private let resultObject: [String: Any] = [
    "total_cost_usd": 0.4321, "duration_ms": 18_500, "num_turns": 3,
    "usage": ["input_tokens": 120, "output_tokens": 900, "cache_read_input_tokens": 40_000, "cache_creation_input_tokens": 2_000],
    "modelUsage": [
        "claude-sonnet-5-5": ["inputTokens": 100, "outputTokens": 800, "cacheReadInputTokens": 30_000, "cacheCreationInputTokens": 1_500, "costUSD": 0.3],
        "claude-haiku-5-5": ["inputTokens": 20, "outputTokens": 100, "cacheReadInputTokens": 10_000, "cacheCreationInputTokens": 500, "costUSD": 0.1321],
    ],
]

let usageTests: [(name: String, run: () throws -> Void)] = [
    ("a result's usage is read from the per-model totals, which include subagents, with the reported cost", {
        guard let totals = UsageTotals.parse(resultObject) else { return check(false, "no usage read") }
        check(totals.models.count == 2, "two models: \(totals.models.keys.sorted())")
        check(totals.models["claude-sonnet-5-5"] == model(input: 100, output: 800, read: 30_000, write: 1_500, cost: 0.3), "sonnet: \(String(describing: totals.models["claude-sonnet-5-5"]))")
        check(totals.reportedCost == 0.4321 && totals.cost == 0.4321, "the reported cost wins: \(String(describing: totals.cost))")
        check(totals.durationMs == 18_500 && totals.turns == 3, "duration and turns")
        check(totals.tokens == 100 + 800 + 1_500 + 20 + 100 + 500, "tokens leave out cache reads: \(totals.tokens)")
        check(totals.cacheReadTokens == 40_000, "cache reads are counted apart")
        check(totals.mainModel == "claude-sonnet-5-5", "the model that wrote most: \(String(describing: totals.mainModel))")
    }),

    ("without per-model totals the main loop's tokens stand in under an unknown model, and no usage at all gives nothing", {
        let loop = UsageTotals.parse(["total_cost_usd": 0.02, "usage": ["input_tokens": 5, "output_tokens": 7]])
        check(loop?.models[UsageTotals.unknownModel] == model(input: 5, output: 7, cost: 0.02), "main loop: \(String(describing: loop))")
        check(UsageTotals.parse(["type": "result", "result": "text"]) == nil, "nothing to read")
        check(UsageTotals.parse([:]) == nil, "empty")
        let costOnly = UsageTotals.parse(["total_cost_usd": 0.5])
        check(costOnly?.cost == 0.5 && costOnly?.models.isEmpty == true, "a cost alone is kept")
    }),

    ("the models' costs add up when no total cost was reported, and a call that reported none has no cost", {
        var totals = UsageTotals(models: ["a": model(output: 1, cost: 0.1), "b": model(output: 1, cost: 0.25)])
        check(totals.cost == 0.35, "added up: \(String(describing: totals.cost))")
        totals.models = ["a": model(input: 10)]
        check(totals.cost == nil, "tokens without any cost")
    }),

    ("a turn is the difference from the session's total before it, per model, and a count that started over stands as it is", {
        let before = UsageTotals(models: ["a": model(input: 10, output: 100, read: 1_000, write: 50, cost: 0.2)], reportedCost: 0.2, durationMs: 5, turns: 1)
        let after = UsageTotals(models: ["a": model(input: 14, output: 160, read: 1_800, write: 80, cost: 0.5), "b": model(output: 30, cost: 0.05)],
                                reportedCost: 0.55, durationMs: 9, turns: 2)
        let share = after.since(before)
        let own = share.models["a"]
        check(own?.input == 4 && own?.output == 60 && own?.cacheRead == 800 && own?.cacheWrite == 30 && abs((own?.cost ?? 0) - 0.3) < 1e-9, "a: \(String(describing: own))")
        check(share.models["b"] == model(output: 30, cost: 0.05), "a model new in this turn counts whole")
        check(abs((share.reportedCost ?? 0) - 0.35) < 1e-9, "cost difference: \(String(describing: share.reportedCost))")
        check(share.durationMs == 9 && share.turns == 2, "duration and turns are the turn's own")
        let reset = UsageTotals(models: ["a": model(input: 2, output: 5, cost: 0.01)], reportedCost: 0.01)
        check(reset.since(before).models["a"] == model(input: 2, output: 5, cost: 0.01), "a lower total means /clear: it stands as it is")
        check(reset.since(before).reportedCost == 0.01, "so does the cost")
        check(after.since(nil) == after, "nothing before it")
        check(after.since(after).models.isEmpty, "an unchanged total is an empty turn")
    }),

    ("a turn is measured against the session's known total, from nothing for a new session and not at all for an unknown old one", {
        let known = UsageTotals(models: ["a": model(output: 100, cost: 1)], reportedCost: 1)
        let reported = UsageTotals(models: ["a": model(output: 130, cost: 1.4)], reportedCost: 1.4, durationMs: 7, turns: 2)
        let next = UsageTotals.measure(reported: reported, known: known, startsFresh: false)
        check(next.counted && next.share.models["a"]?.output == 30 && abs((next.share.cost ?? 0) - 0.4) < 1e-9, "against the known total: \(next)")
        let fresh = UsageTotals.measure(reported: reported, known: nil, startsFresh: true)
        check(fresh.counted && fresh.share == reported, "a new session starts from nothing")
        let unknown = UsageTotals.measure(reported: reported, known: nil, startsFresh: false)
        check(!unknown.counted && unknown.share.models.isEmpty && unknown.share.cost == nil, "an old session's first turn cannot be told")
        check(unknown.share.turns == 2 && unknown.share.durationMs == 7, "though its length is known")
    }),

    ("the log keeps what was appended in order, drops what is older than the retention window and rewrites the file", {
        let log = temporaryLog()
        let now = day(11, 17)
        let old = record("old", at: now.addingTimeInterval(-181 * 86_400), models: ["a": model(output: 5, cost: 0.1)])
        let recent = record("recent", at: now.addingTimeInterval(-3_600), kind: .routine, key: "r1", name: "Morning brief", workspace: "work",
                            models: ["a": model(output: 9, cost: 0.2)], cost: 0.2)
        log.append(old)
        log.append(recent)
        try? Data("{not json}\n".utf8).appendedTo(log.url)
        let loaded = log.load(now: now, calendar: utc)
        check(loaded.map(\.id) == ["recent"], "only the recent one: \(loaded.map(\.id))")
        check(loaded.first == recent, "it reads back as it was written")
        let lines = (try? String(contentsOf: log.url, encoding: .utf8))?.split(separator: "\n").count
        check(lines == 1, "the file was rewritten without the old and the broken line: \(String(describing: lines))")
        check(log.load(now: now, calendar: utc).count == 1, "and reads the same again")
        check(UsageLog(url: log.url.deletingLastPathComponent().appendingPathComponent("none.jsonl")).load(now: now).isEmpty, "no file, no records")
        check(!(String(data: try Data(contentsOf: log.url), encoding: .utf8) ?? "").contains("prompt"), "no prompt text is kept")
    }),

    ("a range starts on the first day it covers, and its days include the empty ones", {
        let now = day(11, 17, hour: 15)
        check(UsageRange.today.start(now: now, calendar: utc) == day(11, 17, hour: 0), "today")
        check(UsageRange.week.start(now: now, calendar: utc) == day(11, 11, hour: 0), "7 days")
        check(UsageRange.month.start(now: now, calendar: utc) == day(10, 19, hour: 0), "30 days")
        let all = [record("a", at: day(11, 16), models: ["m": model(output: 1, cost: 0.5)], cost: 0.5),
                   record("b", at: day(11, 17, hour: 9), workspace: "beta", models: ["m": model(output: 1, cost: 0.25)], cost: 0.25),
                   record("c", at: day(11, 1), models: ["m": model(output: 1, cost: 9)], cost: 9)]
        check(Usage.records(all, in: .week, now: now, calendar: utc).map(\.id) == ["a", "b"], "the week leaves out the first")
        check(Usage.records(all, in: .today, now: now, calendar: utc).map(\.id) == ["b"], "today")
        let days = Usage.days(Usage.records(all, in: .week, now: now, calendar: utc), range: .week, now: now, calendar: utc)
        check(days.count == 7 && days.first?.date == day(11, 11, hour: 0) && days.last?.date == day(11, 17, hour: 0), "seven days")
        check(days.filter { $0.cost == 0 }.count == 5, "five empty days")
        check(days.last?.byWorkspace == ["beta": 0.25] && days[5].byModel == ["m": 0.5], "by workspace and by model: \(days.last as Any)")
    }),

    ("the summary adds up cost and tokens, counts the calls without a cost apart and leaves out a starting point", {
        let all = [record("a", at: day(11, 17), models: ["m": model(input: 10, output: 20, read: 500, cost: 0.4)], cost: 0.4),
                   record("b", at: day(11, 17), models: ["m": model(output: 5)]),
                   record("c", at: day(11, 17), models: [:], counted: false)]
        let summary = Usage.summary(all)
        check(summary.runs == 2 && summary.unpriced == 1, "two counted runs, one without a cost: \(summary)")
        check(abs(summary.cost - 0.4) < 1e-9 && summary.tokens == 35 && summary.cacheReadTokens == 500, "sums: \(summary)")
        check(all[2].cost == nil && all[2].tokens == 0, "a starting point carries nothing")
    }),

    ("the breakdowns group by workspace, agent, routine, automation and model, dearest first, with the models each used", {
        let all = [record("1", at: day(11, 17), kind: .routine, key: "r1", name: "Brief", workspace: "work",
                          models: ["claude-opus-5-5": model(output: 100, cost: 0.8), "claude-haiku-5-5": model(output: 10, cost: 0.05)], cost: 0.85),
                   record("2", at: day(11, 17), kind: .routine, key: "r1", name: "Brief", workspace: "work",
                          models: ["claude-opus-5-5": model(output: 100, cost: 0.7)], cost: 0.7),
                   record("3", at: day(11, 17), kind: .automation, key: "a1", name: "Review requests", workspace: "reviews",
                          models: ["claude-sonnet-5-5": model(output: 50, cost: 0.2)], cost: 0.2),
                   record("4", at: day(11, 17), kind: .assistant, key: "assistant:work:reviewer", name: "Reviewer", workspace: "work",
                          models: ["claude-sonnet-5-5": model(output: 80, cost: 0.1)], cost: 0.1),
                   record("5", at: day(11, 17), kind: .summary, key: nil, name: nil, workspace: nil,
                          models: ["claude-sonnet-5-5": model(output: 8, cost: 0.01)], cost: 0.01)]
        let workspaces = Usage.rows(all, by: .workspace)
        check(workspaces.map(\.name) == ["work", "reviews", Usage.noWorkspace], "workspaces by cost: \(workspaces.map(\.name))")
        check(abs(workspaces[0].cost - 1.65) < 1e-9 && workspaces[0].runs == 3, "work: \(workspaces[0])")
        let routines = Usage.rows(all, by: .routine)
        check(routines.count == 1 && routines[0].name == "Brief" && routines[0].runs == 2, "one routine, two runs: \(routines)")
        check(routines[0].models == ["Opus 5.5", "Haiku 5.5"], "its models by cost, so an Opus default shows: \(routines[0].models)")
        check(Usage.rows(all, by: .automation).map(\.name) == ["Review requests"], "automations")
        let agents = Usage.rows(all, by: .agent)
        check(agents.map(\.name) == ["Brief", "Review requests", "Reviewer", "Meeting summary"], "agents and other calls: \(agents.map(\.name))")
        let models = Usage.rows(all, by: .model)
        check(models.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"], "models: \(models.map(\.name))")
        check(abs(models[0].cost - 1.5) < 1e-9 && models[1].runs == 3, "opus cost and sonnet runs: \(models)")
        check(Usage.expensive(all, limit: 2).map(\.id) == ["1", "2"], "the dearest runs")
    }),

    ("Opus doing short jobs over and over is suggested as a saving, and a few of them or longer ones are not", {
        func short(_ id: String, key: String, turns: Int = 2, output: Int = 300) -> UsageRecord {
            record(id, at: day(11, 17), kind: .routine, key: key, name: "Digest " + key, workspace: "work",
                   models: ["claude-opus-5-5": model(output: output, cost: 0.3)], turns: turns, cost: 0.3)
        }
        let all = (1...3).map { short("a\($0)", key: "x") } + (1...2).map { short("b\($0)", key: "y") }
            + (1...4).map { short("c\($0)", key: "z", turns: 12) } + (1...3).map { short("d\($0)", key: "w", output: 9_000) }
        let ideas = Usage.ideas(all)
        check(ideas.map(\.title) == ["Digest x ran 3 short jobs on Opus"], "only the routine with three short Opus runs: \(ideas.map(\.title))")
        let sonnet = (1...5).map { record("s\($0)", at: day(11, 17), models: ["claude-sonnet-5-5": model(output: 100, cost: 0.05)], cost: 0.05) }
        check(Usage.ideas(sonnet).isEmpty, "nothing to suggest for a smaller model")
    }),

    ("tokens are shortened, money shows cents and a rate turns dollars into euros only once one is entered", {
        check(UsageFormat.tokens(950) == "950" && UsageFormat.tokens(1_234) == "1.2k" && UsageFormat.tokens(41_300) == "41k", "thousands")
        check(UsageFormat.tokens(2_000) == "2k" && UsageFormat.tokens(1_340_000) == "1.3M" && UsageFormat.tokens(23_400_000) == "23M", "millions")
        let dollars = UsageDisplay()
        check(dollars.money(0.18) == "$0.18" && dollars.money(0.001) == "<$0.01" && dollars.money(12.4) == "$12.40" && dollars.money(1_204.6) == "$1205", "dollars")
        check(dollars.money(0) == "$0.00", "nothing")
        check(UsageDisplay(currency: .eur, eurPerUsd: 0).money(1) == "$1.00", "euros without a rate stay dollars")
        check(UsageDisplay(currency: .eur, eurPerUsd: 0.5).money(1) == "\u{20AC}0.50", "euros with a rate")
        let suite = "usage-display-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        check(UsageDisplay.current(defaults: defaults) == UsageDisplay(), "dollars when nothing is stored")
        defaults.set("EUR", forKey: UsageDisplay.currencyKey)
        defaults.set(0.9, forKey: UsageDisplay.rateKey)
        check(UsageDisplay.current(defaults: defaults).shown == .eur, "the stored choice")
        defaults.removePersistentDomain(forName: suite)
    }),

    ("model ids are shown as the app names them, else by family and version, else as they are", {
        check(UsageFormat.modelName("claude-sonnet-5-5") == "Sonnet 5.5" && UsageFormat.modelName("claude-opus-5-5") == "Opus 5.5", "the app's own names")
        check(UsageFormat.modelName("claude-opus-4-7") == "Opus 4.7", "family and version")
        check(UsageFormat.modelName("claude-3-5-haiku-20241022") == "Haiku 3.5", "a dated id")
        check(UsageFormat.modelName("some-other-model") == "some-other-model", "not a Claude id")
        check(UsageFormat.modelName("unknown") == "unknown", "the stand-in")
    }),

    ("a finished turn's line ends with its tokens and cost, and says nothing about usage when none was measured", {
        let dollars = UsageDisplay()
        let share = UsageTotals(models: ["claude-sonnet-5-5": model(input: 1_000, output: 40_000, read: 90_000, cost: 0.18)], reportedCost: 0.18)
        check(AgentLogic.resultLine(turns: 3, model: "claude-sonnet-5-5", usage: share, display: dollars) == "Done \u{00B7} 3 turns \u{00B7} Sonnet 5.5 \u{00B7} 41k tokens \u{00B7} $0.18",
              "full line: \(AgentLogic.resultLine(turns: 3, model: "claude-sonnet-5-5", usage: share, display: dollars))")
        check(AgentLogic.resultLine(turns: 1, model: "claude-sonnet-5-5") == "Done \u{00B7} 1 turn \u{00B7} Sonnet 5.5", "as before without usage")
        check(AgentLogic.resultLine(turns: 2, usage: UsageTotals(), display: dollars) == "Done \u{00B7} 2 turns", "an empty share adds nothing")
        let tokensOnly = UsageTotals(models: ["m": model(output: 2_000)])
        check(AgentLogic.resultLine(turns: 2, usage: tokensOnly, display: dollars) == "Done \u{00B7} 2 turns \u{00B7} 2k tokens", "tokens without a cost")
        check(AgentLogic.resultLine(turns: 2, mode: .auto, usage: share, display: UsageDisplay(currency: .eur, eurPerUsd: 0.5)).hasSuffix("41k tokens \u{00B7} \u{20AC}0.09"), "in euros")
    }),

    ("the sidecar's result line carries the usage, which goes into the transcript's last line", {
        let line = #"{"type":"result","sessionId":"s1","isError":false,"text":"ok","turns":2,"model":"claude-sonnet-5-5","usage":{"total_cost_usd":0.2,"modelUsage":{"claude-sonnet-5-5":{"inputTokens":5,"outputTokens":3000,"costUSD":0.2}},"num_turns":2}}"#
        guard case .result(_, _, _, let turns, _, _, let usage)? = AgentEvent.decode(line, cwd: "/tmp") else { return check(false, "no result") }
        check(turns == 2 && usage?.cost == 0.2 && usage?.tokens == 3_005, "usage decoded: \(String(describing: usage))")
        let plain = #"{"type":"result","sessionId":"s1","isError":false,"text":"ok","turns":2,"model":"claude-sonnet-5-5"}"#
        guard case .result(_, _, _, _, _, _, let none)? = AgentEvent.decode(plain, cwd: "/tmp") else { return check(false, "no plain result") }
        check(none == nil, "no usage in an older sidecar's line")
        var items: [AgentItem] = []
        AgentLogic.apply(.result(sessionID: "s1", isError: false, text: "", turns: 2, model: "claude-sonnet-5-5", usage: usage), to: &items)
        if case .status(let text)? = items.last?.kind { check(text.contains("3k tokens"), "the line: \(text)") } else { check(false, "no status line") }
    }),

    ("a run over the limit is announced, and a day over its budget once a day", {
        let dollars = UsageDisplay()
        let now = day(11, 17)
        let key = UsageAlerts.dayKey(now, calendar: utc)
        check(key == "2026-11-17", "day key: \(key)")
        let costly = record("big", at: now, kind: .routine, key: "r", name: "Digest", models: ["m": model(output: 9, cost: 1.5)], cost: 1.5)
        let off = UsageAlerts.alerts(for: costly, todayBefore: 5, limits: UsageLimits(), display: dollars, dayKey: key, notifiedDay: nil)
        check(off.isEmpty, "nothing is announced while the limits are off")
        let run = UsageAlerts.alerts(for: costly, todayBefore: 0, limits: UsageLimits(perRun: 1), display: dollars, dayKey: key, notifiedDay: nil)
        check(run.map(\.title) == ["Digest used $1.50"] && !run[0].isDaily, "a run over the limit: \(run)")
        check(UsageAlerts.alerts(for: costly, todayBefore: 0, limits: UsageLimits(perRun: 2), display: dollars, dayKey: key, notifiedDay: nil).isEmpty,
              "a run under the limit")
        let budget = UsageLimits(dailyBudget: 4)
        let crossing = UsageAlerts.alerts(for: costly, todayBefore: 3, limits: budget, display: dollars, dayKey: key, notifiedDay: nil)
        check(crossing.count == 1 && crossing[0].isDaily && crossing[0].title == "Today's usage passed $4.00", "the day crosses its budget: \(crossing)")
        check(UsageAlerts.alerts(for: costly, todayBefore: 3, limits: budget, display: dollars, dayKey: key, notifiedDay: key).isEmpty, "only once a day")
        check(UsageAlerts.alerts(for: costly, todayBefore: 5, limits: budget, display: dollars, dayKey: key, notifiedDay: nil).isEmpty, "already over before this run")
        let start = record("start", at: now, models: [:], counted: false)
        check(UsageAlerts.alerts(for: start, todayBefore: 0, limits: UsageLimits(perRun: 0.01), display: dollars, dayKey: key, notifiedDay: nil).isEmpty,
              "a starting point says nothing")
        let suite = "usage-limits-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        check(UsageLimits.stored(defaults: defaults) == UsageLimits(), "off when nothing is stored")
        defaults.set(2.5, forKey: UsageLimits.perRunKey)
        defaults.set(0, forKey: UsageLimits.dailyKey)
        check(UsageLimits.stored(defaults: defaults) == UsageLimits(perRun: 2.5, dailyBudget: nil), "a limit of zero is off")
        defaults.removePersistentDomain(forName: suite)
    }),

    ("the plan's windows are read with their reset times, per-model windows and extra usage in the plan's currency", {
        let object: [String: Any] = [
            "subscription": "team",
            "limits": [
                "five_hour": ["utilization": 24, "resets_at": "2026-11-17T23:19:59.890837+00:00"],
                "seven_day": ["utilization": 67.5, "resets_at": "2026-11-20T13:59:59+00:00"],
                "model_scoped": [["display_name": "Orchid", "utilization": 30, "resets_at": "2026-11-20T13:59:59.891085+00:00"]],
                "extra_usage": ["is_enabled": true, "monthly_limit": 10_000, "used_credits": 404, "utilization": 4.04, "currency": "EUR"],
            ],
        ]
        guard let plan = UsagePlan.parse(object) else { return check(false, "no plan read") }
        check(plan.subscription == "team", "subscription")
        check(plan.windows.map(\.title) == ["5-hour limit", "Weekly \u{00B7} all models", "Weekly \u{00B7} Orchid"], "windows: \(plan.windows.map(\.title))")
        check(plan.windows[0].percent == 24 && plan.windows[1].percent == 67.5, "percentages")
        check(plan.windows.allSatisfy { $0.resets != nil }, "every window resets at a time, with or without fractions")
        check(plan.extra?.used == 4.04 && plan.extra?.limit == 100 && plan.extra?.currency == "EUR", "extra usage in hundredths: \(String(describing: plan.extra))")
        check(UsagePlan.parse(["limits": [String: Any]()]) == nil && UsagePlan.parse([:]) == nil, "no windows, no plan")
        let now = day(11, 17, hour: 0)
        check(UsagePlan.resetText(now.addingTimeInterval(4 * 3_600 + 55 * 60), now: now) == "resets in 4h 55m", "hours")
        check(UsagePlan.resetText(now.addingTimeInterval(2 * 86_400 + 19 * 3_600), now: now) == "resets in 2d 19h", "days")
        check(UsagePlan.resetText(now.addingTimeInterval(20), now: now) == "resets in 1m", "never zero minutes")
    }),

    ("a call made anywhere reports to the connected store, tokens alone included, and an empty one reports nothing", {
        final class Seen: @unchecked Sendable {
            var calls: [(UsageTotals, UsageKind, String?)] = []
        }
        let seen = Seen()
        UsageReport.connect { totals, kind, name, _ in seen.calls.append((totals, kind, name)) }
        UsageReport.note(call: UsageTotals(models: ["m": model(output: 10, cost: 0.1)]), kind: .analysis, name: "Digest")
        UsageReport.note(tokens: 100, output: 20, model: "claude-sonnet-5-5", kind: .summary)
        UsageReport.note(call: UsageTotals(), kind: .summary)
        UsageReport.note(call: nil, kind: .summary)
        UsageReport.connect(nil)
        UsageReport.note(call: UsageTotals(models: ["m": model(output: 1)]), kind: .summary)
        check(seen.calls.count == 2, "two reports: \(seen.calls.count)")
        check(seen.calls[0].1 == .analysis && seen.calls[0].2 == "Digest", "the first one")
        check(seen.calls[1].0.models["claude-sonnet-5-5"] == model(input: 100, output: 20) && seen.calls[1].0.cost == nil, "tokens without a cost")
    }),

    ("the plan helper's answer is a plan, no plan or a reason, from its last line", {
        let ok = #"{"plan":{"subscription":"team","limits":{"five_hour":{"utilization":10,"resets_at":"2026-11-17T23:00:00+00:00"}}}}"#
        guard case .plan(let plan) = UsagePlanOutcome.parse("warning line\n" + ok + "\n") else { return check(false, "no plan") }
        check(plan.windows.map(\.percent) == [10], "the window")
        check(UsagePlanOutcome.parse(#"{"plan":null}"#) == .notApplicable, "limits that do not apply")
        check(UsagePlanOutcome.parse(#"{"plan":{"limits":{}}}"#) == .notApplicable, "a plan with nothing in it")
        check(UsagePlanOutcome.parse(#"{"error":"not signed in"}"#) == .failed("not signed in"), "an error")
        check(UsagePlanOutcome.parse("") == .failed("Claude Code gave no answer."), "silence")
        check(UsagePlanOutcome.parse("not json") == .failed("Claude Code gave no answer."), "noise")
    }),
]

private extension Data {
    func appendedTo(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
