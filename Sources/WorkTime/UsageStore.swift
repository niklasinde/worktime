import Combine
import Foundation

/// What every call to Claude used: kept in a log file, loaded when the app starts and shown on the usage page. The totals are what
/// Claude Code reports, an estimate and not a bill.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var records: [UsageRecord]
    private let log: UsageLog
    private let defaults: UserDefaults
    private let alerts: Bool
    /// Each session's running total as Claude Code last reported it, which its next turn is measured against.
    private var baselines: [String: UsageTotals] = [:]

    init(log: UsageLog = UsageLog(url: AppPaths.usageLog), defaults: UserDefaults = .standard, alerts: Bool = true, now: Date = Date()) {
        self.log = log
        self.defaults = defaults
        self.alerts = alerts
        records = log.load(now: now)
        for record in records {
            if let session = record.session, let cumulative = record.cumulative { baselines[session] = cumulative }
        }
    }

    /// Records a turn of an agent from the total Claude Code reported for its session, and returns the turn's own share for its footer.
    @discardableResult
    func record(turn reported: UsageTotals, session: String?, startsFresh: Bool, kind: UsageKind, key: String?, name: String?,
                workspace: String?, failed: Bool = false, now: Date = Date()) -> UsageTotals {
        let measured = UsageTotals.measure(reported: reported, known: session.flatMap { baselines[$0] }, startsFresh: startsFresh)
        if let session { baselines[session] = reported }
        guard !measured.counted || !measured.share.isEmpty else { return measured.share }
        add(UsageRecord(id: UUID().uuidString, date: now, session: session, kind: kind, key: key, name: name, workspace: workspace,
                        totals: measured.share, cumulative: session == nil ? nil : reported, counted: measured.counted, failed: failed))
        return measured.share
    }

    /// Records a call that stands alone, such as a summary through the CLI: what it used is all its own.
    func record(call totals: UsageTotals, session: String? = nil, kind: UsageKind, key: String? = nil, name: String? = nil,
                workspace: String? = nil, failed: Bool = false, now: Date = Date()) {
        guard !totals.isEmpty else { return }
        add(UsageRecord(id: UUID().uuidString, date: now, session: session, kind: kind, key: key, name: name, workspace: workspace,
                        totals: totals, failed: failed))
    }

    /// Lets calls made anywhere in the app report to this store.
    static func connectReports() {
        UsageReport.connect { totals, kind, name, date in
            Task { @MainActor in shared.record(call: totals, kind: kind, name: name, now: date) }
        }
    }

    private func add(_ record: UsageRecord) {
        let today = Usage.records(records, in: .today, now: record.date)
        let before = Usage.summary(today).cost
        records.append(record)
        log.append(record)
        guard alerts else { return }
        let key = UsageAlerts.dayKey(record.date)
        let found = UsageAlerts.alerts(for: record, todayBefore: before, limits: .stored(defaults: defaults), display: .current(defaults: defaults),
                                       dayKey: key, notifiedDay: defaults.string(forKey: UsageLimits.budgetDayKey))
        for alert in found {
            if alert.isDaily { defaults.set(key, forKey: UsageLimits.budgetDayKey) }
            Notifier.postUsageAlert(title: alert.title, body: alert.body, identifier: alert.identifier)
        }
    }

    // MARK: Asking

    /// What the calls of one session cost, nil when none reported a cost.
    func cost(session: String) -> Double? {
        let costs = records.lazy.filter { $0.session == session && $0.counted }.compactMap(\.cost)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// What the calls of a routine or automation cost since a run started, with the tokens; nil when none was recorded.
    func spent(key: String, since start: Date) -> (cost: Double?, tokens: Int)? {
        let mine = records.filter { $0.key == key && $0.counted && $0.date >= start }
        guard !mine.isEmpty else { return nil }
        let costs = mine.compactMap(\.cost)
        return (costs.isEmpty ? nil : costs.reduce(0, +), mine.reduce(0) { $0 + $1.tokens })
    }
}

/// The plan's limits (the 5-hour and weekly windows), asked of Claude Code through the sidecar's one-shot helper. The call behind it is
/// experimental in the Agent SDK, so a failure is shown as such and the rest of the page does not depend on it.
@MainActor
final class UsagePlanModel: ObservableObject {
    static let shared = UsagePlanModel()
    static let staleAfter: TimeInterval = 300

    @Published private(set) var outcome: UsagePlanOutcome?
    @Published private(set) var loading = false
    @Published private(set) var fetched: Date?

    #if DEBUG
    func preview(_ outcome: UsagePlanOutcome) {
        self.outcome = outcome
        fetched = Date()
    }
    #endif

    func refreshIfStale(now: Date = Date()) {
        if let fetched, now.timeIntervalSince(fetched) < Self.staleAfter { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".nvm/versions/node").path)) ?? []
        guard let node = AgentLogic.nodeCandidates(path: environment["PATH"], home: home, nvmVersions: nvm)
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            outcome = .failed("Node.js was not found.")
            return
        }
        guard let script = AgentLogic.sidecarCandidates(environment: environment, resources: Bundle.main.resourceURL, sourceFile: #filePath)
            .map({ $0.deletingLastPathComponent().appendingPathComponent("plan.js") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            outcome = .failed("The agent sidecar is not built.")
            return
        }
        loading = true
        let childEnvironment = AgentLogic.childEnvironment(environment, nodeFolder: node.deletingLastPathComponent().path, mcpCommand: nil)
        Task { [weak self] in
            let started = Date()
            let output = await Self.run(node: node, script: script, environment: childEnvironment)
            let outcome = UsagePlanOutcome.parse(output)
            var failure = false
            if case .failed = outcome { failure = true }
            RequestLog.shared.record(service: .anthropic, what: "plan usage", bytes: output.utf8.count, started: started, status: (failure ? "failed" : "ok", failure))
            guard let self else { return }
            self.outcome = outcome
            self.fetched = Date()
            self.loading = false
        }
    }

    /// Runs the helper and collects what it prints; one that takes more than a minute is stopped.
    private nonisolated static func run(node: URL, script: URL, environment: [String: String], timeout: TimeInterval = 60) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = node
            process.arguments = [script.path]
            process.currentDirectoryURL = script.deletingLastPathComponent()
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let box = PlanOutput()
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { box.append(data) }
            }
            process.terminationHandler = { _ in
                output.fileHandleForReading.readabilityHandler = nil
                box.append(output.fileHandleForReading.availableData)
                continuation.resume(returning: box.text)
            }
            do {
                try process.run()
            } catch {
                return continuation.resume(returning: #"{"error":"Claude Code could not be started."}"#)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}

private final class PlanOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock()
        data.append(more)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
