import Charts
import SwiftUI

/// Settings → Usage: how full the plan is, and what the calls to Claude used and cost, by day and by who made them.
struct UsagePage: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var plan: UsagePlanModel
    @AppStorage("usageRange") private var rangeName = UsageRange.week.rawValue
    @AppStorage("usageGroup") private var groupName = UsageGroup.agent.rawValue
    @AppStorage("usageChartBy") private var chartByModel = false
    @AppStorage(UsageDisplay.currencyKey) private var currencyName = UsageCurrency.usd.rawValue
    @AppStorage(UsageDisplay.rateKey) private var rate = 0.0
    @State private var now = Date()

    private var range: UsageRange { UsageRange(rawValue: rangeName) ?? .week }
    private var group: UsageGroup { UsageGroup(rawValue: groupName) ?? .agent }
    private var display: UsageDisplay { UsageDisplay(currency: UsageCurrency(rawValue: currencyName) ?? .usd, eurPerUsd: rate) }
    private var shown: [UsageRecord] { Usage.records(store.records, in: range, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            planSection
            totalsSection
            if !shown.isEmpty {
                chartSection
                breakdownSection
                expensiveSection
                ideasSection
            }
            RequestLogSection(log: .shared)
            SettingsSection("About these numbers", footer: nil) {
                Text("Cost is what Claude Code estimates for each call at API prices: an estimate, not a bill. On a subscription your usage counts against the plan's "
                     + "limits above, not a charge per call. Subagents and compaction are included in their agent's cost, cache reads are not counted in tokens, "
                     + "and a call that reported no cost is counted without one. Nothing you wrote or Claude answered is kept here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .onAppear {
            now = Date()
            plan.refreshIfStale()
        }
    }

    // MARK: Plan

    @ViewBuilder private var planSection: some View {
        SettingsSection("Plan limits", footer: "From Claude Code's own usage data. The call behind it is experimental in the Agent SDK, so it may stop working in a later release.") {
            switch plan.outcome {
            case .plan(let found):
                ForEach(Array(found.windows.enumerated()), id: \.element.id) { index, window in
                    if index > 0 { Divider().padding(.leading, 14) }
                    windowRow(window)
                }
                if let extra = found.extra {
                    Divider().padding(.leading, 14)
                    extraRow(extra)
                }
            case .notApplicable:
                SettingsRow("No plan limits", detail: "Claude Code reports none: it runs on an API key or a provider, not a Claude subscription.") {}
            case .failed(let message):
                SettingsRow("Could not read the plan limits", detail: message) { refreshButton }
            case nil:
                SettingsRow("Reading the plan limits\u{2026}") { ProgressView().controlSize(.small) }
            }
            if case .plan(let found) = plan.outcome {
                Divider().padding(.leading, 14)
                SettingsRow(found.subscription.map { "Claude \($0.capitalized) plan" } ?? "Claude plan",
                            detail: plan.fetched.map { "Read \(GitHubLogic.updatedText($0, now: now))" }) { refreshButton }
            }
        }
    }

    private var refreshButton: some View {
        Button { plan.refresh() } label: {
            if plan.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.borderless)
        .disabled(plan.loading)
        .help("Read the plan limits again")
    }

    private func windowRow(_ window: UsagePlan.Window) -> some View {
        SettingsRow(window.title, detail: window.resets.map { UsagePlan.resetText($0, now: now) }) {
            ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                .tint(window.percent >= 90 ? .red : window.percent >= 75 ? .orange : .accentColor)
                .frame(width: 140)
            Text("\(Int(window.percent.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    private func extraRow(_ extra: UsagePlan.Extra) -> some View {
        let currency = extra.currency ?? "USD"
        let detail = [extra.used.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) + " " + currency + " spent" },
                      extra.limit.map { "of " + String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), $0) + " a month" }]
            .compactMap { $0 }.joined(separator: " ")
        return SettingsRow("Extra usage", detail: detail.isEmpty ? nil : detail) {
            if let percent = extra.percent {
                ProgressView(value: min(max(percent, 0), 100), total: 100).frame(width: 140)
                Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    // MARK: Totals

    @ViewBuilder private var totalsSection: some View {
        let summary = Usage.summary(shown)
        SettingsSection("Usage", footer: summary.unpriced > 0 ? "\(summary.unpriced) of \(summary.runs) calls reported no cost, which the total leaves out." : nil) {
            SettingsRow("Range") {
                Picker("Range", selection: $rangeName) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider().padding(.leading, 14)
            if shown.isEmpty {
                SettingsRow("Nothing yet", detail: "Calls to Claude are counted from this version on, as agents and routines run.") {}
            } else {
                SettingsRow("Estimated cost", detail: "\(summary.runs) call\(summary.runs == 1 ? "" : "s")") {
                    Text(display.money(summary.cost)).font(.title3.weight(.semibold)).monospacedDigit()
                }
                Divider().padding(.leading, 14)
                SettingsRow("Tokens", detail: "\(UsageFormat.tokens(summary.cacheReadTokens)) more read from the cache") {
                    Text(UsageFormat.tokens(summary.tokens)).monospacedDigit()
                }
            }
        }
    }

    // MARK: Chart

    private struct Point: Identifiable {
        let date: Date
        let series: String
        let cost: Double

        var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    }

    private var points: [Point] {
        Usage.days(shown, range: range, now: now).flatMap { day -> [Point] in
            let parts = chartByModel ? day.byModel.map { (UsageFormat.modelName($0.key), $0.value) } : day.byWorkspace.map { ($0.key, $0.value) }
            return parts.filter { $0.1 > 0 }.map { Point(date: day.date, series: $0.0, cost: display.shown == .eur ? $0.1 * display.eurPerUsd : $0.1) }
        }
    }

    @ViewBuilder private var chartSection: some View {
        SettingsSection("By day", footer: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Colour by", selection: $chartByModel) {
                    Text("Workspace").tag(false)
                    Text("Model").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Chart(points) { point in
                    BarMark(x: .value("Day", point.date, unit: .day), y: .value("Cost", point.cost))
                        .foregroundStyle(by: .value("Series", point.series))
                }
                .chartYAxis { AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(display.shown.symbol + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)) } }
                } }
                .frame(height: 160)
            }
            .padding(12)
        }
    }

    // MARK: Breakdown

    @ViewBuilder private var breakdownSection: some View {
        let rows = Usage.rows(shown, by: group)
        SettingsSection("Who used it", footer: group == .routine || group == .automation
                        ? "The models are listed by cost, so a routine or automation left on an expensive one shows here." : nil) {
            SettingsRow("Group by") {
                Picker("Group by", selection: $groupName) {
                    ForEach(UsageGroup.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if rows.isEmpty {
                Divider().padding(.leading, 14)
                SettingsRow("None in this range") {}
            }
            ForEach(rows.prefix(12)) { row in
                Divider().padding(.leading, 14)
                SettingsRow(row.name, detail: rowDetail(row)) {
                    if let kind = row.kind { Image(systemName: kind.symbol).foregroundStyle(.secondary) }
                    Text(row.cost > 0 || row.unpriced == 0 ? display.money(row.cost) : "no cost").monospacedDigit().frame(minWidth: 60, alignment: .trailing)
                }
            }
            if rows.count > 12 {
                Divider().padding(.leading, 14)
                SettingsRow("\(rows.count - 12) more") {}
            }
        }
    }

    private func rowDetail(_ row: UsageRow) -> String {
        var parts = ["\(row.runs) call\(row.runs == 1 ? "" : "s")", UsageFormat.tokens(row.tokens) + " tokens"]
        if !row.models.isEmpty { parts.append(row.models.joined(separator: ", ")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Expensive runs

    @ViewBuilder private var expensiveSection: some View {
        let runs = Usage.expensive(shown)
        if !runs.isEmpty {
            SettingsSection("Most expensive calls", footer: nil) {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider().padding(.leading, 14) }
                    SettingsRow(record.name ?? record.kind.title,
                                detail: [GitHubLogic.updatedText(record.date, now: now), record.mainModel.map(UsageFormat.modelName),
                                         UsageFormat.tokens(record.tokens) + " tokens", record.totals.turns.map { "\($0) turn\($0 == 1 ? "" : "s")" }]
                                    .compactMap { $0 }.joined(separator: " \u{00B7} ")) {
                        Text(display.money(record.cost ?? 0)).monospacedDigit()
                        if let key = record.agentKey {
                            Button("Open") { AgentHub.shared.show(key) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    // MARK: Ideas

    @ViewBuilder private var ideasSection: some View {
        let ideas = Usage.ideas(shown)
        if !ideas.isEmpty {
            SettingsSection("Ways to use less", footer: nil) {
                ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                    if index > 0 { Divider().padding(.leading, 14) }
                    SettingsRow(idea.title, detail: idea.detail) { Image(systemName: "lightbulb").foregroundStyle(.yellow) }
                }
            }
        }
    }
}

/// Settings → Agent → Usage: how money is shown, and the two warnings.
struct UsageSettings: View {
    @AppStorage(UsageDisplay.currencyKey) private var currencyName = UsageCurrency.usd.rawValue
    @AppStorage(UsageDisplay.rateKey) private var rate = 0.0
    @AppStorage(UsageLimits.perRunKey) private var perRun = 0.0
    @AppStorage(UsageLimits.dailyKey) private var daily = 0.0

    var body: some View {
        SettingsSection("Usage", footer: "What every call to Claude used is kept here for half a year, without what was asked or answered; see Settings \u{2192} Usage. "
                        + "The limits are in dollars. A warning is a notification: it stops nothing.") {
            SettingsRow("Show costs in", detail: currencyName == UsageCurrency.eur.rawValue && rate <= 0 ? "Enter a rate to see euros." : nil) {
                Picker("Show costs in", selection: $currencyName) {
                    ForEach(UsageCurrency.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if currencyName == UsageCurrency.eur.rawValue {
                Divider().padding(.leading, 14)
                SettingsRow("Euros for one dollar") {
                    TextField("0.00", value: $rate, format: .number.precision(.fractionLength(0...4)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Warn when one run costs more than", detail: perRun > 0 ? nil : "Off") {
                TextField("Off", value: $perRun, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("USD").foregroundStyle(.secondary)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Warn when a day passes", detail: daily > 0 ? "Once a day, when the day's total crosses it." : "Off") {
                TextField("Off", value: $daily, format: .number.precision(.fractionLength(0...2)))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("USD").foregroundStyle(.secondary)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Usage page") {
                Button("Open") { SettingsModel.shared.show(tab: .usage) }
            }
        }
    }
}
