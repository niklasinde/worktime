import SwiftUI

/// The Agent beside a pull request: one model per pull request for this run of the app, in the place of its Claude terminal.
/// The sidecar starts on the first prompt; only the most recently opened few keep theirs, the rest start again on the next prompt.
@MainActor
final class PRAgents: ObservableObject {
    static let shared = PRAgents()
    static let runningLimit = 3

    @Published private(set) var models: [String: AgentModel] = [:]
    @Published private(set) var shown: Set<String> = []
    private var recent: [String] = []

    func model(for key: String) -> AgentModel? { models[key] }

    func isShown(_ key: String) -> Bool { models[key] != nil && shown.contains(key) }

    /// Shows the pull request's agent, made in its checkout with the review prompt waiting the first time. Without the
    /// embedded panes (the swiftc build) it shows on the Main page instead.
    func open(_ target: GitHubLink.Target) {
        let topics = TopicAgentStore.shared.topics
        if let set = PullRequestSets.set(containing: target.url, in: topics), !set.archived { return AgentHub.shared.show(set.key) }
        guard EmbeddedTerminalModel.available else { return AgentHub.shared.show(target.url) }
        let key = target.url
        if models[key] != nil { return show(key) }
        Task { @MainActor in
            _ = await load(target)
            show(key)
        }
    }

    /// The pull request's agent, made in its checkout (continuing its saved session) when it is not loaded yet.
    func load(_ target: GitHubLink.Target) async -> AgentModel {
        if let model = models[target.url] { return model }
        let checkout = await Task.detached { GitHubClaude.checkout(for: target.repo, under: GitHubClaudeModel.repositoriesRoot) }.value
        if let model = models[target.url] { return model }
        let model = AgentModel()
        model.open(pr: target, checkout: checkout)
        models[target.url] = model
        return model
    }

    /// A prompt from Main for a pull request's agent, sent without showing it; a notification says where it went.
    func deliver(_ request: AgentInbox.Request) async -> AgentInbox.Reply {
        guard let target = GitHubLink.pullRequest(at: request.agent) else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "Not a pull request url.")
        }
        return Self.deliver(request, to: await load(target), title: AgentOverview.prTitle(target.url))
    }

    /// Hands Main's prompt to the agent and says how it went; a notification says where it went.
    static func deliver(_ request: AgentInbox.Request, to model: AgentModel, title: String) -> AgentInbox.Reply {
        switch model.deliver(fromMain: request.text, origin: request.origin) {
        case .reject(let why): return AgentInbox.Reply(id: request.id, status: .rejected, message: why)
        case .start, .queue:
            let queued = !model.queued.isEmpty
            Notifier.postAgentMessage(title: "Main \u{2192} \(title)", body: request.text, agent: model.attentionID)
            let slot = model.waitingForSlot ? TicketSessions.slotNote(limit: SessionSlots.limit(), roleLimit: model.slotRole?.limit) : nil
            return AgentInbox.Reply(id: request.id, status: queued ? .queued : .started, sessionID: model.sessionID, message: queued ? "queued" : "started",
                                    note: slot)
        }
    }

    func show(_ key: String) {
        shown.insert(key)
        EmbeddedTerminalModel.shared.setShown(key, false)
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        for old in recent.dropFirst(Self.runningLimit) where models[old]?.busy == false { models[old]?.stopClient() }
    }

    func hide(_ key: String) { shown.remove(key) }

    /// Stops the agent and forgets its transcript; the session stays saved, so opening it again continues it.
    func close(_ key: String) {
        models[key]?.stopClient()
        models[key] = nil
        shown.remove(key)
        recent.removeAll { $0 == key }
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    #if DEBUG
    func showSample(_ key: String, model: AgentModel) {
        models[key] = model
        show(key)
    }
    #endif
}

/// The agent's pane on the pull request page: a compact header over the same transcript and composer as the Agent window.
struct AgentDockPane: View {
    let key: String
    @ObservedObject var model: AgentModel
    let page: GitHubDetailModel

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= AgentWorkMap.sideMinWidth
            VStack(spacing: 0) {
                header(wide: wide)
                Divider()
                AgentWorkMapSplit(model: model, wide: wide) { AgentPanel(model: model, gutter: 16) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reveal = { [weak page] in page?.reveal(file: $0) ?? false } }
    }

    private func header(wide: Bool) -> some View {
        let folder = (model.folder as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 8) {
            Circle().fill(model.busy ? Color.green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                .help(model.busy ? "The agent is working" : "The agent is idle")
            Text("Agent").font(.callout.weight(.medium))
            if !model.queued.isEmpty {
                Text("\(model.queued.count) from Main queued").font(.caption).foregroundStyle(.purple)
                    .help("Prompts from Main that start when the current one finishes")
            }
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                .help("The agent works in \(folder)")
            AgentWorktreeNote(folder: model.folder)
            Spacer(minLength: 4)
            AgentSessionsButton(model: model).labelStyle(.iconOnly)
            AgentChromeToggle(model: model).labelStyle(.iconOnly)
            AgentPermissionPicker(model: model)
            AgentSessionAllowButton(model: model).labelStyle(.iconOnly)
            AgentModelPicker(model: model)
            AgentNewSessionButton(model: model).buttonStyle(.bordered).labelStyle(.titleOnly)
            AgentWorkMapToggle(model: model, wide: wide).labelStyle(.iconOnly)
            AgentOverflowMenu(model: model)
            Divider().frame(height: 14)
            DockPlacementMenu()
            Button { PRAgents.shared.hide(key) } label: { Image(systemName: "chevron.down") }
                .help("Hide the agent; its transcript is kept")
            Button { PRAgents.shared.close(key) } label: { Image(systemName: "xmark") }
                .help("Close the agent and stop it; Open in Agent continues the saved session")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Where the pane goes: picked in the Agent's and the terminal's header and shared by both.
struct DockPlacementMenu: View {
    @AppStorage(DockPlacement.choiceKey) private var choice = DockPlacement.Choice.automatic

    var body: some View {
        Menu {
            Picker("Placement", selection: $choice) {
                ForEach(DockPlacement.Choice.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: choice.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Placement: \(choice.title)")
    }
}

/// A second after the agents change, refreshes the Main page's list and writes `agents.json` for the MCP server, the file
/// only once started by the app (never by previews).
@MainActor
final class AgentStateWriter: ObservableObject {
    static let shared = AgentStateWriter()
    @Published private(set) var revision = 0
    private var url: URL?
    private var scheduled = false

    func start(url: URL = AppPaths.agentState) {
        self.url = url
        changed()
    }

    func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.write() }
    }

    private func write() {
        scheduled = false
        revision += 1
        guard let url else { return }
        let current = states()
        LinkIndexer.shared.schedule()
        StatePublisher.shared.publish(states: current)
        let data = AgentOverview.encode(current, now: Date())
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func states() -> [AgentState] {
        let workspaces = WorkspaceStore.shared
        var states = workspaces.workspaces.compactMap { workspace in
            AgentHub.shared.mains[workspace.id].map { state($0, key: workspace.mainKey, title: "Main \u{00B7} \(workspace.name)") }
        }
        let titles = Dictionary(GitHubModel.shared.prs.values.joined().map { ($0.url, $0.title) }) { first, _ in first }
        for (url, model) in PRAgents.shared.models.sorted(by: { $0.key < $1.key }) {
            states.append(state(model, key: url, title: AgentOverview.prTitle(url, title: titles[url])))
        }
        let sessions = AgentModel.savedSessions
        let topics = TopicAgentStore.shared
        for topic in topics.visible {
            let loaded = topics.models[topic.key].map { state($0, key: topic.key, title: topic.name) }
            states.append(AgentState.topic(topic, loaded: loaded, sessionID: sessions[topic.key],
                                           roleName: topic.assistant.flatMap { AssistantStore.shared.entry($0)?.role.name }))
        }
        for topic in topics.archived where topic.assistant != nil {
            states.append(AgentState.topic(topic, loaded: nil, sessionID: sessions[topic.key],
                                           roleName: topic.assistant.flatMap { AssistantStore.shared.entry($0)?.role.name }))
        }
        let assistants = AssistantStore.shared
        for entry in assistants.all {
            let loaded = assistants.models[entry.key].map { state($0, key: entry.key, title: entry.role.name) }
            states.append(AgentState.assistant(entry, loaded: loaded, sessionID: sessions[entry.key], folder: assistants.folder(entry)))
        }
        return AgentOverview.withPersisted(states, sessions: sessions, known: Array(AgentSessionStore.all().keys)).map { state in
            var state = state
            if !state.loaded, let title = titles[state.key] { state.title = AgentOverview.prTitle(state.key, title: title) }
            state.workspace = workspaces.assigned(state)
            state.spaces = workspaces.spaces(of: state)
            return state
        }
    }

    private func state(_ model: AgentModel, key: String, title: String) -> AgentState {
        var state = AgentOverview.snapshot(key: key, title: title, prURL: model.prURL, folder: model.folder, sessionID: model.sessionID, items: model.items,
                                           busy: model.busy, seen: model.resultSeen, updatedAt: model.updated, queued: model.queued.count)
        if model.waitingForSlot { state.slotWait = true }
        return state
    }
}

/// Takes the prompts the MCP server's send_to_agent leaves in the inbox folder and answers each with a reply file.
@MainActor
final class AgentInboxWatcher {
    static let shared = AgentInboxWatcher()
    private var timer: Timer?
    private var folder = AppPaths.agentInbox

    func start(folder: URL = AppPaths.agentInbox) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        timer?.invalidate()
        purge()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        for request in take(NoticeRequest.self, where: NoticeLogic.isRequest) {
            answer(NoticeCenter.shared.handle(request), to: request.id)
        }
        for request in take(ReminderRequest.self, where: ReminderLogic.isRequest) {
            Task { @MainActor in answer(TodoModel.shared.handle(request), to: request.id) }
        }
        for request in take(RoutineRequest.self, where: RoutineRequests.isRequest) {
            answer(RoutineStore.shared.handle(request), to: request.id)
        }
        for request in take(AssistantRequest.self, where: AssistantRequests.isRequest) {
            answer(AssistantStore.shared.handle(request), to: request.id)
        }
        for request in take(BriefRequest.self, where: MeetingBriefLogic.isRequest) {
            Task { @MainActor in answer(await MeetingBriefModel.shared.answer(request), to: request.id) }
        }
        for request in take(WorkspaceRequest.self, where: WorkspaceRequests.isRequest) {
            answer(WorkspaceStore.shared.handle(request), to: request.id)
        }
        for request in take(OpenRequest.self, where: OpenLinks.isRequest) {
            answer(Self.open(request), to: request.id)
        }
        for request in take(AgentInbox.Request.self, where: AgentInbox.isRequest) {
            Task { @MainActor in answer(await Self.route(request), to: request.id) }
        }
        for request in take(ReportRequest.self, where: AgentReports.isRequest) {
            Task { @MainActor in answer(Self.report(request), to: request.id) }
        }
    }

    @MainActor static var reports = AgentReports.Ledger()

    /// What the app does to show an `open_in_app` target; the app delegate sets it.
    @MainActor static var openHandler: ((OpenTarget) -> Void)?

    @MainActor static func open(_ request: OpenRequest) -> NoticeReply {
        switch OpenLinks.target(request, agents: AgentStateWriter.shared.states()) {
        case .failure(let error): return NoticeReply(id: request.id, ok: false, notice: nil, message: error.message)
        case .success(let target):
            openHandler?(target)
            return NoticeReply(id: request.id, ok: true, notice: nil, message: "Showing it in WorkTime.")
        }
    }

    /// Async requests' records and replies nobody read are dropped after a day.
    private func purge(now: Date = Date()) {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where RequestStatuses.isRecord(name) || name.hasSuffix(".reply.json") {
            let url = folder.appendingPathComponent(name)
            if let date = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, now.timeIntervalSince(date) > 86_400 { try? fileManager.removeItem(at: url) }
        }
    }

    /// An agent's send_to_main: checked against the limits, then handed to the Main it names, with a notification unless the user is looking at it.
    @MainActor static func report(_ request: ReportRequest, now: Date = Date(), hub: AgentHub? = nil) -> NoticeReply {
        let hub = hub ?? AgentHub.shared
        func answer(ok: Bool, _ message: String) -> NoticeReply { NoticeReply(id: request.id, ok: ok, notice: nil, message: message) }
        switch AgentReports.decide(request, workspaces: WorkspaceStore.shared.workspaces, titles: NoticeCenter.shared.titles(),
                                   queued: { hub.mains[$0]?.queued ?? [] }, ledger: reports, now: now) {
        case .reject(let why): return answer(ok: false, why)
        case .duplicate: return answer(ok: true, AgentReports.duplicateText)
        case .deliver(let workspace, let name, let prompt):
            guard let main = hub.mains[workspace] else { return answer(ok: false, "WorkTime has no Main for the workspace \(workspace) yet; restart it to add one.") }
            let decision = main.deliver(report: prompt)
            if case .reject(let why) = decision { return answer(ok: false, why) }
            reports.record(caller: request.source.identity, text: request.text, now: now)
            if !main.isBeingWatched {
                Notifier.postReport(title: "\(name) \u{2192} Main", body: request.text, agent: main.attentionID)
            }
            return answer(ok: true, AgentReports.replyText(decision, workspace: workspace))
        }
    }

    /// Hands the prompt to the agent it names: an assistant, a topic agent or a pull request's.
    static func route(_ request: AgentInbox.Request) async -> AgentInbox.Reply {
        let reply = await deliver(request)
        if reply.status != .rejected, let space = request.space, request.ticket == nil, request.pr == nil, !Assistants.isKey(request.agent) {
            WorkspaceStore.shared.add(space: space, to: PullRequestSets.set(containing: request.agent, in: TopicAgentStore.shared.topics)?.key ?? request.agent)
        }
        return reply
    }

    private static func deliver(_ request: AgentInbox.Request) async -> AgentInbox.Reply {
        if let problem = AgentInbox.problem(request, now: Date()) {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: problem.message)
        }
        if let urls = request.prs, urls.count > 1 { return await TopicAgentStore.shared.deliverSet(request) }
        if let set = PullRequestSets.set(containing: request.agent, in: TopicAgentStore.shared.topics), !set.archived {
            var forSet = request
            forSet.agent = set.key
            return TopicAgentStore.shared.deliver(forSet)
        }
        if TopicAgents.isKey(request.agent) { return TopicAgentStore.shared.deliver(request) }
        if request.ticket != nil || request.pr != nil, Assistants.isKey(request.agent) { return await TopicAgentStore.shared.deliver(roleSession: request) }
        if Assistants.isKey(request.agent) { return AssistantStore.shared.deliver(request) }
        return await PRAgents.shared.deliver(request)
    }

    /// A prompt the user chose to send, from a notification's button: the same path as Main's send_to_agent, which asks first.
    static func send(_ text: String, to agent: String, pullRequests: [String]? = nil, ticket: String? = nil, pr: String? = nil, origin: String? = nil,
                     space: String? = nil) async -> AgentInbox.Reply {
        await route(AgentInbox.Request(id: UUID().uuidString, agent: agent, text: String(text.prefix(AgentInbox.textLimit)), created: Date(), prs: pullRequests,
                                       ticket: ticket, pr: pr, origin: origin, space: space))
    }

    /// Takes the inbox's requests of one kind off the folder, dropping any that cannot be read.
    private func take<Request: Decodable>(_ type: Request.Type, where isRequest: (String) -> Bool) -> [Request] {
        let fileManager = FileManager.default
        return ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter(isRequest).compactMap { name in
            let url = folder.appendingPathComponent(name)
            let data = try? Data(contentsOf: url)
            try? fileManager.removeItem(at: url)
            return data.flatMap { AgentInbox.decode(type, from: $0) }
        }
    }

    private func answer<Reply: Encodable>(_ reply: Reply, to id: String) {
        try? AgentInbox.encode(reply).write(to: folder.appendingPathComponent(AgentInbox.replyName(id)), options: .atomic)
    }
}
