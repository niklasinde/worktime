import Combine
import Foundation

/// The feed of events a coordinator polls, kept in a small capped file.
@MainActor
final class AppEventLog {
    static let shared = AppEventLog()
    private var file: AppEvents.File
    private let url: URL?

    init(url: URL? = AppPaths.eventLog) {
        self.url = url
        file = url.map { AppEvents.decode(try? Data(contentsOf: $0)) } ?? AppEvents.File()
    }

    func record(_ drafts: [AppEvents.Draft], now: Date = Date()) {
        guard !drafts.isEmpty else { return }
        file = AppEvents.appending(drafts, to: file, now: now)
        guard let url else { return }
        let data = AppEvents.encode(file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func record(_ kind: AppEvents.Kind, _ text: String, session: String? = nil, ticket: String? = nil, link: String? = nil) {
        record([AppEvents.Draft(kind: kind, text: text, session: session, ticket: ticket, link: link)])
    }
}

/// Writes what the MCP server's coordinator tools read, each when it changes: `decisions.json`, `timeline.json` and `app.json`, and appends the
/// events the changes mean. Started once by the app, never by previews.
@MainActor
final class StatePublisher {
    static let shared = StatePublisher()
    nonisolated static let transcriptBudget = 12
    static let timelineInterval: TimeInterval = 5

    var recording: () -> Bool = { false }
    private var started = Date()
    private var running = false
    private var states: [AgentState]?
    private var decisions: [PendingDecision]?
    private var postedKnown: Set<String>?
    private var cache: [String: (stamp: String, events: [TimelineEvent])] = [:]
    private var scanning = false
    private var lastPass = Date.distantPast
    private var rescan: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?
    private var sidecar = "unknown"
    private var sidecarChecked = Date.distantPast

    func start() {
        guard !running else { return }
        running = true
        started = Date()
        AppEventLog.shared.record(.appRestarted, "WorkTime started")
        let changes: [AnyPublisher<Void, Never>] = [
            AgentAttentionCenter.shared.$approvals.map { _ in }.eraseToAnyPublisher(),
            TicketAskStore.shared.$pending.map { _ in }.eraseToAnyPublisher(),
            NoticeCenter.shared.$notices.map { _ in }.eraseToAnyPublisher(),
        ]
        subscriptions = [Publishers.MergeMany(changes).debounce(for: .milliseconds(500), scheduler: RunLoop.main).sink { [weak self] in
            MainActor.assumeIsolated { self?.publishDecisions() }
        }]
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
    }

    /// Called whenever the agents' state is written.
    func publish(states new: [AgentState]) {
        guard running else { return }
        if let old = states { AppEventLog.shared.record(AppEvents.sessionEvents(old: old, new: new)) }
        states = new
        publishDecisions()
        writeInfo()
        refreshTimelines(new)
    }

    private func heartbeat() {
        guard let states else { return }
        publishDecisions(force: true)
        writeInfo()
        refreshTimelines(states)
    }

    // MARK: Decisions

    private func publishDecisions(force: Bool = false) {
        let approvals = AgentAttentionCenter.shared.approvals.filter { !$0.ticketAsk }.map {
            DecisionApproval(agent: $0.agent, permission: $0.permission, kind: $0.blocked ? .blocked : $0.roleTool ? .roleTool : .call,
                             title: $0.title, body: $0.body, created: $0.created)
        }
        let made = PendingDecisions.make(approvals: approvals, ticketAsks: TicketAskStore.shared.pending, notices: NoticeCenter.shared.notices,
                                         agents: states ?? [], titles: NoticeCenter.shared.titles())
        if let old = decisions, old != made { AppEventLog.shared.record(AppEvents.decisionEvents(old: old, new: made)) }
        guard force || decisions != made else { return }
        decisions = made
        write(PendingDecisions.encode(made, now: Date()), to: AppPaths.decisionState)
    }

    // MARK: App info

    private func writeInfo(now: Date = Date()) {
        guard let states else { return }
        if now.timeIntervalSince(sidecarChecked) > 60 {
            sidecar = Self.sidecarStatus()
            sidecarChecked = now
        }
        let bundle = Bundle.main.infoDictionary ?? [:]
        let work = AppInfos.work(states, routines: RoutineStore.shared.routines.filter { RoutineStore.shared.isRunning($0) }.map(\.name))
        var plan: [AppInfo.PlanWindow]?
        if case .plan(let found)? = UsagePlanModel.shared.outcome {
            plan = found.windows.map { AppInfo.PlanWindow(title: $0.title, percent: $0.percent, resets: $0.resets) }
        }
        let executable = Bundle.main.executableURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let info = AppInfo(written: now, version: bundle["CFBundleShortVersionString"] as? String ?? "1.0", build: bundle["CFBundleVersion"] as? String,
                           commit: (bundle[Self.commitKey] as? String).flatMap { $0.isEmpty ? nil : $0 },
                           buildDate: (bundle[Self.buildDateKey] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? executable,
                           pid: ProcessInfo.processInfo.processIdentifier, started: started, dataFolder: AppPaths.support.path,
                           diagnosticsFolder: AppPaths.diagnostics.path, schemaVersion: MCPServer.schemaVersion,
                           workspaces: WorkspaceStore.shared.workspaces.map { AppInfo.Workspace(id: $0.id, name: $0.name, spaces: $0.spaces.map(\.name)) },
                           sidecar: sidecar, working: work.working, waiting: work.waiting, queuedPrompts: states.reduce(0) { $0 + $1.queued },
                           recording: recording(), plan: plan, planFetched: UsagePlanModel.shared.fetched)
        write(AppInfos.encode(info), to: AppPaths.appInfo)
    }

    static let commitKey = "WorkTimeCommit"
    static let buildDateKey = "WorkTimeBuildDate"

    private static func sidecarStatus() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".nvm/versions/node").path)) ?? []
        guard AgentLogic.nodeCandidates(path: environment["PATH"], home: home, nvmVersions: nvm).contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return "Node.js was not found; the agents cannot start"
        }
        let built = AgentLogic.sidecarCandidates(environment: environment, resources: Bundle.main.resourceURL, sourceFile: #filePath)
            .contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("dist/main.js").path) }
        return built ? "built and Node.js found" : "not built (run npm ci && npm run build in the agent folder)"
    }

    // MARK: Timelines

    private func schedule(after delay: TimeInterval) {
        rescan?.cancel()
        rescan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let states = self.states else { return }
            self.refreshTimelines(states)
        }
    }

    private func refreshTimelines(_ states: [AgentState]) {
        let wait = Self.timelineInterval - Date().timeIntervalSince(lastPass)
        guard !scanning, wait <= 0 else { return schedule(after: max(wait, 1)) }
        lastPass = Date()
        let workspaces = WorkspaceStore.shared
        let projects = Set(workspaces.workspaces.flatMap(\.jiraProjects).map { $0.uppercased() })
        let titles = Dictionary(GitHubModel.shared.prs.values.joined().map { ($0.url, $0.title) }) { first, _ in first }
        var groups: [TicketGroup] = []
        for row in TicketGrouping.rows(states, projects: projects, titles: titles) {
            switch row {
            case .group(let group): groups.append(group)
            case .agent(let state):
                if let url = state.prURL, let group = TicketGrouping.group(SessionSubject.pullRequest(url).key, in: [state], projects: projects, titles: titles) { groups.append(group) }
            }
        }
        groups = Array(groups.filter { $0.members.contains { $0.sessionID != nil } }.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
            .prefix(TimelineSnapshots.groupLimit))
        let wanted = Dictionary(groups.flatMap(\.members).compactMap { state in state.sessionID.map { (state.key, (state, $0)) } }) { first, _ in first }
        let known = cache.mapValues(\.stamp)
        let root = ClaudeTranscripts.projectsFolder
        scanning = true
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> Scan in Self.scan(wanted: wanted, known: known, root: root) }.value
            let (scanned, more) = (outcome.scanned, outcome.more)
            guard let self else { return }
            self.scanning = false
            for (key, entry) in scanned { self.cache[key] = entry }
            for key in self.cache.keys where wanted[key] == nil { self.cache[key] = nil }
            let posted = Dictionary(groups.map { ($0.id, TimelineModel.postedEvents($0)) }) { first, _ in first }
            let made = TimelineSnapshots.capped(groups.map { group in
                TimelineSnapshots.group(group, events: Timeline.folded(Timeline.merged(group.members.map { self.cache[$0.key]?.events ?? [] } + [posted[group.id] ?? []])),
                                        title: group.members.first { $0.roleKey == nil }?.title)
            })
            let seen = AppEvents.postedIDs(made)
            if let before = self.postedKnown { AppEventLog.shared.record(AppEvents.postedEvents(known: before, groups: made)) }
            self.postedKnown = seen
            self.write(TimelineSnapshots.encode(made, now: Date()), to: AppPaths.timelineState)
            if more { self.schedule(after: 3) }
        }
    }

    /// Reads the transcripts that changed since the cache, at most `transcriptBudget` of them; true when more are left.
    private typealias Scan = (scanned: [String: (stamp: String, events: [TimelineEvent])], more: Bool)

    private nonisolated static func scan(wanted: [String: (AgentState, String)], known: [String: String], root: URL) -> Scan {
        var scanned: [String: (stamp: String, events: [TimelineEvent])] = [:]
        var budget = transcriptBudget, more = false
        for (key, (state, session)) in wanted {
            guard let url = AgentTranscript.url(sessionID: session, cwd: state.folder, root: root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let stamp = "\(session)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes[.size] as? Int ?? 0)"
            guard known[key] != stamp else { continue }
            guard budget > 0 else { more = true; continue }
            budget -= 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var scanner = TimelineScanner(session: key, label: TicketGrouping.label(state))
            scanner.update(AgentTranscript.items(jsonl: text, cwd: state.folder ?? ""))
            scanned[key] = (stamp, scanner.events)
        }
        return (scanned, more)
    }

    private func write(_ data: Data, to url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
