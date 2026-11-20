import AppKit
import SwiftUI

/// The topic agents: kept in a file the MCP server reads too, each with its own folder in the app's data folder. Their
/// models are made when first shown and live for this run of the app, like the pull requests' agents.
@MainActor
final class TopicAgentStore: ObservableObject {
    static let shared = TopicAgentStore()

    @Published private(set) var topics: [TopicAgent]
    @Published private(set) var models: [String: AgentModel] = [:]
    private var recent: [String] = []
    private var file: URL
    private var root: URL

    init(file: URL = AppPaths.topicAgents, root: URL = AppPaths.topicFolders) {
        self.file = file
        self.root = root
        topics = TopicAgents.decode(try? Data(contentsOf: file))
    }

    var visible: [TopicAgent] { topics.filter { !$0.archived } }
    var archived: [TopicAgent] { topics.filter(\.archived) }

    func topic(_ key: String) -> TopicAgent? { topics.first { $0.key == key } }

    enum LinkChoice { case existing(String), create, cancel }

    func matches(_ links: [LinkEntity], workspace: String? = nil) -> [AgentState] {
        guard !links.isEmpty else { return [] }
        return TopicAgents.matching(links: links, states: AgentStateWriter.shared.states(), table: LinkStore.shared.table, workspace: workspace)
    }

    func choose(_ links: [LinkEntity], matches found: [AgentState]? = nil) -> LinkChoice {
        let agents = found ?? matches(links)
        guard !agents.isEmpty else { return .create }
        let alert = NSAlert()
        alert.messageText = "An agent is already linked"
        alert.informativeText = "Continue with a linked agent or create a new one for " + links.map(\.id).joined(separator: ", ") + "?"
        let picker = NSPopUpButton()
        for agent in agents {
            let detail = agent.lastPrompt.map { " · " + String($0.prefix(48)) } ?? ""
            picker.addItem(withTitle: agent.title + detail + " (" + String(agent.key.suffix(8)) + ")")
        }
        picker.sizeToFit()
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue Existing")
        alert.addButton(withTitle: "Create New")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .existing(agents[picker.indexOfSelectedItem].key)
        case .alertSecondButtonReturn: return .create
        default: return .cancel
        }
    }

    func openExisting(_ key: String, links: [LinkEntity]) {
        LinkStore.shared.link(agent: key, to: links)
        AgentHub.shared.showExact(key)
    }

    /// Makes the topic and its folder, or says what is wrong with what was typed.
    func make(name: String, jira: String, slack: String, folder: URL? = nil, links: [LinkEntity] = []) -> Result<TopicAgent, TopicAgentError> {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let taken = Set(topics.map { URL(fileURLWithPath: $0.folder).lastPathComponent } + folders)
        let made = TopicAgents.make(name: name, jira: jira, slack: slack, root: root, taken: taken, folder: folder?.path, now: Date())
        if case .success(let topic) = made {
            if folder == nil { try? FileManager.default.createDirectory(atPath: topic.folder, withIntermediateDirectories: true) }
            LinkStore.shared.link(agent: topic.key, to: topic.linkTargets + links)
            topics.append(topic)
            save()
        }
        return made
    }

    /// A topic continuing a Claude Code session in the session's own folder, which is never removed with the topic.
    func make(importing session: String, name: String, folder: String) -> TopicAgent {
        let topic = TopicAgents.imported(name: name, folder: folder, session: session, now: Date())
        topics.append(topic)
        save()
        return topic
    }

    func show(_ key: String) { AgentHub.shared.show(key) }

    /// Open in Agent on a Jira ticket: its topic agent, made the first time with the prompt to read the ticket waiting, in
    /// `folder` when given instead of a folder of its own. `isNew` says whether it was made now.
    @discardableResult
    func open(ticket: JiraTicket, folder: URL? = nil, links: [LinkEntity] = []) -> (topic: TopicAgent, isNew: Bool)? {
        let targets = [LinkEntity.jira(ticket.key)] + links
        switch choose(targets) {
        case .existing(let key):
            openExisting(key, links: targets)
            return topic(key).map { ($0, false) }
        case .cancel: return nil
        case .create: break
        }
        guard case .success(let topic) = make(name: TopicAgents.name(ticket: ticket.key, summary: ticket.summary), jira: ticket.key, slack: "",
                                               folder: folder, links: links) else { return nil }
        show(topic.key)
        return (topic, true)
    }

    /// Open in Agent on a Slack message: the topic agent for its thread, made the first time.
    func open(slack message: SlackMessage, link: URL?) {
        let thread = link.flatMap { SlackLogic.threadLink($0.absoluteString) }
        let links = thread.map { [LinkEntity.slack($0.url)] } ?? []
        switch choose(links) {
        case .existing(let key): return openExisting(key, links: links)
        case .cancel: return
        case .create: break
        }
        if case .success(let topic) = make(name: TopicAgents.name(slackPlace: message.place, author: message.author), jira: "", slack: thread?.url ?? "") {
            if thread == nil { load(topic).draft = "Help me with this Slack message from \(message.author ?? message.place): \(message.text)" }
            show(topic.key)
        }
    }

    /// The agent working on these pull requests together: the one already on all of them, else a new one with a folder of its own
    /// (or the repository's checkout they share).
    @discardableResult
    func makeSet(_ prs: [LinkedPR], forceNew: Bool = false) -> TopicAgent {
        if !forceNew, let existing = PullRequestSets.set(coveringAll: prs.map(\.url), in: topics) {
            add(prs, to: existing.key)
            return topic(existing.key) ?? existing
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let taken = Set(topics.map { URL(fileURLWithPath: $0.folder).lastPathComponent } + folders)
        let name = PullRequestSets.name(prs)
        let own = root.appendingPathComponent(TopicAgents.uniqueSlug(name, taken: taken), isDirectory: true).path
        let folder = PullRequestSets.workingFolder(prs, own: own)
        let set = TopicAgent(id: UUID().uuidString, name: name, folder: folder, created: Date(), pullRequests: prs)
        if folder == own { try? FileManager.default.createDirectory(atPath: own, withIntermediateDirectories: true) }
        apply(topics + [set])
        return set
    }

    /// Makes the set for these pull requests, with their checkouts looked up, and shows it.
    func openSet(_ prs: [LinkedPR]) {
        Task { @MainActor in
            let prs = await Self.withCheckouts(prs)
            let links = prs.map { LinkEntity.pullRequest($0.target) }
            switch choose(links) {
            case .existing(let key):
                if topic(key) != nil { add(prs, to: key) }
                openExisting(key, links: links)
            case .create: reopen(makeSet(prs, forceNew: true))
            case .cancel: break
            }
        }
    }

    /// The pull requests with the checkout of each repository filled in where one is known.
    static func withCheckouts(_ prs: [LinkedPR]) async -> [LinkedPR] {
        let repos = Array(Set(prs.filter { $0.checkout == nil }.map(\.repo)))
        let found = await Task.detached { Dictionary(uniqueKeysWithValues: repos.compactMap { repo in
            GitHubClaude.checkout(for: repo, under: GitHubClaudeModel.repositoriesRoot).map { (repo, $0.path) }
        }) }.value
        return prs.map { pr in
            var pr = pr
            pr.checkout = pr.checkout ?? found[pr.repo]
            return pr
        }
    }

    /// Adds pull requests to an agent (a set or any other topic).
    func add(_ prs: [LinkedPR], to key: String) {
        var updated = topics
        guard let index = updated.firstIndex(where: { $0.key == key }) else { return }
        updated[index].pullRequests = PullRequestSets.adding(prs, to: updated[index].linked)
        apply(updated)
    }

    /// Takes a pull request out of the agent: it opens its own agent again.
    func remove(_ url: String, from key: String) {
        var updated = topics
        guard let index = updated.firstIndex(where: { $0.key == key }) else { return }
        let remaining = PullRequestSets.removing(url, from: updated[index].linked)
        updated[index].pullRequests = remaining.isEmpty ? nil : remaining
        apply(updated)
    }

    /// Saves the topics and hands a changed list of pull requests to the loaded agents; their next prompt carries it.
    private func apply(_ updated: [TopicAgent]) {
        let before = Dictionary(uniqueKeysWithValues: topics.map { ($0.key, $0.linked) })
        topics = updated
        for topic in topics where before[topic.key] != topic.linked {
            let previous = Set((before[topic.key] ?? []).compactMap { LinkTargets.pullRequest($0.url) })
            let current = Set(topic.linked.compactMap { LinkTargets.pullRequest($0.url) })
            LinkStore.shared.link(agent: topic.key, to: Array(current.subtracting(previous)))
            for removed in previous.subtracting(current) { LinkStore.shared.remove(LinkPair(.agent(topic.key), removed)) }
            models[topic.key]?.open(topic: topic)
        }
        save()
    }

    private func reopen(_ topic: TopicAgent) {
        if topic.archived { setArchived(topic.key, false) }
        show(topic.key)
    }

    /// The topic's agent, made in its folder (continuing its saved session) when it is not loaded yet.
    @discardableResult
    func load(_ topic: TopicAgent) -> AgentModel {
        let model = models[topic.key] ?? AgentModel(folder: topic.folder)
        if models[topic.key] == nil {
            if let owned = TopicAgents.ownedFolder(topic, root: root) { try? FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true) }
            model.open(topic: topic)
            models[topic.key] = model
        }
        recent.removeAll { $0 == topic.key }
        recent.insert(topic.key, at: 0)
        for old in recent.dropFirst(PRAgents.runningLimit) where models[old]?.busy == false { models[old]?.stopClient() }
        return model
    }

    /// Points the topic at another folder; returns the updated topic.
    func setFolder(_ key: String, to folder: String) -> TopicAgent? {
        guard let index = topics.firstIndex(where: { $0.key == key }) else { return nil }
        topics[index].folder = folder
        save()
        return topics[index]
    }

    /// Hidden from the lists; the folder and the sessions stay, so unarchiving continues where it was.
    func setArchived(_ key: String, _ archived: Bool) {
        guard let index = topics.firstIndex(where: { $0.key == key }) else { return }
        if archived { unload(key) }
        topics[index].archived = archived
        save()
    }

    /// Forgets the topic and removes its folder; Claude Code's own transcripts of its sessions are left alone.
    func delete(_ key: String) {
        guard let topic = topic(key) else { return }
        unload(key)
        if let folder = TopicAgents.ownedFolder(topic, root: root) { try? FileManager.default.removeItem(at: folder) }
        AgentModel.savedSessions[key] = nil
        _ = AgentSessionStore.update(key) { _ in [] }
        topics.removeAll { $0.key == key }
        save()
    }

    func deliverPullRequests(_ request: AgentInbox.Request) async -> AgentInbox.Reply {
        guard case .success(let prs) = PullRequestSets.linked(request.prs ?? [request.agent]), let first = prs.first else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "A pull request is required.")
        }
        let prepared = await Self.withCheckouts(prs)
        let workspace = WorkspaceStore.shared.assigned(AgentState(key: first.url, title: first.label, prURL: first.url, status: .idle))
        let candidates = matches(request.linkTargets, workspace: workspace)
        if !candidates.isEmpty {
            return await ask(request, candidates: candidates, workspace: workspace, subject: .pullRequest(first.url), role: "Pull request")
        }
        if prs.count == 1 {
            let model = PRAgents.shared.load(first.target, checkout: prepared.first?.checkout.map { URL(fileURLWithPath: $0) })
            return PRAgents.deliver(request, to: model, title: AgentOverview.prTitle(first.url))
        }
        return createPRSession(request, prs: prepared, workspace: workspace)
    }

    private func createPRSession(_ request: AgentInbox.Request, prs: [LinkedPR], workspace: String) -> AgentInbox.Reply {
        let set = makeSet(prs, forceNew: true)
        WorkspaceStore.shared.move(set.key, to: workspace)
        return send(request, to: set, note: TicketSessions.createdNote(name: set.name), created: true)
    }

    private func ask(_ request: AgentInbox.Request, candidates: [AgentState], workspace: String, subject: SessionSubject, role: String) async -> AgentInbox.Reply {
        let previews = candidates.map { state in
            TicketSessions.Preview(key: state.key, title: state.title, state: TicketSessions.stateText(state), updated: state.updatedAt,
                                   excerpt: TicketSessions.clip(state.lastResult ?? state.lastPrompt ?? ""))
        }
        let now = Date(), seconds = RoleTools.waitSeconds()
        let ask = TicketAsk(id: request.id, workspace: workspace, assistant: request.agent, assistantName: role, ticket: subject.ticket,
                            pullRequest: subject.pullRequest, existing: previews[0], text: request.text, created: now,
                            deadline: now.addingTimeInterval(TimeInterval(seconds)), origin: request.origin, space: request.space, links: request.linkTargets,
                            candidates: previews, request: request)
        return await waitForAnswer(ask)
    }

    private func waitForAnswer(_ ask: TicketAsk) async -> AgentInbox.Reply {
        guard TicketAsks.pending(assistant: ask.assistant, subject: ask.subject, in: TicketAskStore.shared.pending) == nil else {
            return AgentInbox.Reply(id: ask.id, status: .rejected, message: "A choice for this agent and subject is already waiting.")
        }
        guard let (chosen, answer) = await TicketAskStore.shared.ask(ask) else {
            return AgentInbox.Reply(id: ask.id, status: .rejected, message: "The linked agent choice expired. Nothing was sent.", timedOut: true)
        }
        return await finish(ask: chosen, answer: answer)
    }

    func deliver(_ request: AgentInbox.Request) -> AgentInbox.Reply {
        guard let topic = topic(request.agent), !topic.archived else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "No topic agent \(request.agent) in WorkTime.")
        }
        return PRAgents.deliver(request, to: load(topic), title: topic.name)
    }

    // MARK: Ticket and pull request sessions

    /// Makes the assistant's session for the ticket or pull request, working in the assistant's own folder, without showing it.
    @discardableResult
    func makeSession(_ entry: AssistantEntry, subject: SessionSubject, links: [LinkEntity] = []) -> TopicAgent {
        let folder = AssistantStore.shared.folder(entry)
        if entry.role.folder == Assistants.ownFolder { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let topic = TicketSessions.make(entry: entry, subject: subject, folder: folder, now: Date())
        LinkStore.shared.link(agent: topic.key, to: topic.linkTargets + links)
        topics.append(topic)
        save()
        return topic
    }

    /// What a request is about: the ticket it names, else the ticket the pull request's title names, else the pull request itself.
    func subject(of request: AgentInbox.Request, entry: AssistantEntry) -> SessionSubject? {
        if let ticket = request.ticket { return .ticket(ticket) }
        guard let url = request.pr else { return nil }
        let projects = WorkspaceStore.shared.workspace(entry.workspace)?.jiraProjects ?? []
        let title = GitHubModel.shared.prs.values.joined().first { $0.url == url }?.title
        return TicketSessions.ticket(inTitle: title, projects: projects).map(SessionSubject.ticket) ?? .pullRequest(url)
    }

    /// A prompt for an assistant about one ticket or pull request: sent to the session it already has for it or to a new one. With a session
    /// already there, the user decides unless the setting or `new_session` does, and the answer is waited for, but only as long as the
    /// setting says.
    func deliver(roleSession request: AgentInbox.Request) async -> AgentInbox.Reply {
        func reject(_ message: String) -> AgentInbox.Reply { AgentInbox.Reply(id: request.id, status: .rejected, message: message) }
        let assistants = AssistantStore.shared
        guard let entry = assistants.entry(request.agent) else { return reject("No assistant \(request.agent) in WorkTime.") }
        guard entry.role.isUsable else { return reject(AssistantError.broken(entry.role.name, entry.role.problems.first?.text ?? "").message) }
        guard let subject = subject(of: request, entry: entry) else { return reject("A ticket or a pull request is needed.") }
        let existing = TicketSessions.existing(assistant: entry.key, subject: subject, in: topics)
        let subjectLinks = [subject.ticket.map(LinkEntity.jira), subject.pullRequest.flatMap(LinkTargets.pullRequest)].compactMap { $0 }
        if request.newSession != true {
            let candidates = matches(request.linkTargets + subjectLinks, workspace: entry.workspace)
            if candidates.contains(where: { $0.key != existing?.key }),
               existing == nil || (TicketSessions.policy() == .ask && !TicketSessions.alwaysReuse().contains(entry.key)) {
                return await ask(request, candidates: candidates, workspace: entry.workspace, subject: subject, role: entry.role.name)
            }
        }
        switch TicketSessions.resolve(existing: existing, forceNew: request.newSession == true, policy: TicketSessions.policy(),
                                      alwaysReuse: TicketSessions.alwaysReuse().contains(entry.key)) {
        case .create:
            let topic = makeSession(entry, subject: subject, links: request.linkTargets)
            return send(request, to: topic, note: TicketSessions.createdNote(name: topic.name), created: true)
        case .reuse(let topic):
            return send(request, to: topic, note: TicketSessions.reusedNote(name: topic.name, preview: nil, now: Date()))
        case .ask(let topic):
            let now = Date(), seconds = RoleTools.waitSeconds()
            let state = AgentStateWriter.shared.states().first { $0.key == topic.key }
            let ask = TicketAsk(id: request.id, workspace: entry.workspace, assistant: entry.key, assistantName: entry.role.name, ticket: subject.ticket,
                                pullRequest: subject.pullRequest, existing: TicketSessions.preview(of: topic, state: state), text: request.text, created: now,
                                deadline: now.addingTimeInterval(TimeInterval(seconds)), origin: request.origin, space: request.space, links: request.linkTargets)
            return await waitForAnswer(ask)
        }
    }

    /// Delivers the pending prompt to the selected agent or a newly created session.
    func finish(ask: TicketAsk, answer: TicketSessions.Answer, request: AgentInbox.Request? = nil) async -> AgentInbox.Reply {
        let request = request ?? ask.request ?? AgentInbox.Request(id: ask.id, agent: ask.assistant, text: ask.text, created: Date(), ticket: ask.ticket, pr: ask.pullRequest,
                                                    origin: ask.origin, space: ask.space, links: ask.links)
        if answer == .cancel { return AgentInbox.Reply(id: ask.id, status: .rejected, message: "Cancelled. Nothing was sent.") }
        if ask.candidates != nil {
            if answer != .startNew {
                let key = ask.existing.key
                if let topic = topic(key), !topic.archived {
                    return send(request, to: topic, note: TicketSessions.chosenNote(.reuse, name: topic.name))
                }
                if let target = GitHubLink.pullRequest(at: key) {
                    var exact = request
                    exact.links = request.linkTargets
                    exact.agent = target.url
                    var reply = await PRAgents.shared.deliver(exact)
                    reply.note = TicketSessions.chosenNote(.reuse, name: ask.existing.title)
                    return reply
                }
                return AgentInbox.Reply(id: ask.id, status: .rejected, message: "The selected agent is no longer available.")
            }
            if !Assistants.isKey(request.agent), case .success(let prs) = PullRequestSets.linked(request.prs ?? [request.agent]) {
                return createPRSession(request, prs: await Self.withCheckouts(prs), workspace: ask.workspace)
            }
        }
        guard let entry = AssistantStore.shared.entry(ask.assistant), entry.role.isUsable else {
            return AgentInbox.Reply(id: request.id, status: .rejected, message: "The assistant \(ask.assistantName) is gone; nothing was sent.")
        }
        if answer != .startNew {
            guard let topic = topic(ask.existing.key), !topic.archived else {
                return AgentInbox.Reply(id: ask.id, status: .rejected, message: "The selected agent is no longer available.")
            }
            if answer == .alwaysReuse { TicketSessions.setAlwaysReuse(ask.assistant) }
            return send(request, to: topic, note: TicketSessions.chosenNote(answer, name: topic.name))
        }
        let topic = makeSession(entry, subject: ask.subject, links: request.linkTargets)
        return send(request, to: topic, note: TicketSessions.chosenNote(.startNew, name: topic.name), created: true)
    }

    private func send(_ request: AgentInbox.Request, to topic: TopicAgent, note: String, created: Bool = false) -> AgentInbox.Reply {
        var forTopic = request
        forTopic.links = request.linkTargets
        forTopic.agent = topic.key
        forTopic.ticket = nil
        forTopic.pr = nil
        forTopic.newSession = nil
        var reply = deliver(forTopic)
        reply.note = [note, reply.note].compactMap { $0 }.joined(separator: " ")
        if created, reply.status != .rejected { reply.created = true }
        return reply
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    private func unload(_ key: String) {
        models[key]?.stopClient()
        models[key] = nil
        recent.removeAll { $0 == key }
        if AgentHub.shared.selected == key { AgentHub.shared.selected = AgentHub.shared.currentMainKey }
    }

    private func save() {
        let data = TopicAgents.encode(topics), file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        AgentStateWriter.shared.changed()
    }

    #if DEBUG
    /// Points the store at a folder of its own, for the previews.
    func useSample(file: URL, root: URL) {
        models.values.forEach { $0.stopClient() }
        self.file = file
        self.root = root
        topics = []
        models = [:]
    }
    #endif
}

/// A topic's agent on the Main page, loaded the first time it is picked.
struct AgentTopicPage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var store = TopicAgentStore.shared

    var body: some View {
        if let model = store.models[key] {
            AgentView(model: model, listHidden: $listHidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) { if let topic = store.topic(key) { store.load(topic) } }
        }
    }
}

/// The topic agent's name and links in its header.
struct AgentTopicHeader: View {
    let topic: TopicAgent
    @ObservedObject private var jira = JiraModel.shared

    var body: some View {
        Label { Text(topic.name).lineLimit(1) } icon: { AgentTopicIcon(kind: topic.kind) }
            .font(.system(size: 15, weight: .medium))
        if let role = topic.assistant.flatMap({ AssistantStore.shared.entry($0)?.role.name }) {
            Text(role).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.purple.opacity(0.14), in: Capsule()).foregroundStyle(.purple)
                .help("This session works as the \(role) assistant, for \(topic.jiraKey ?? "this ticket") only")
        }
        if let key = topic.jiraKey {
            Button { jira.site.flatMap { JiraLogic.browseURL(site: $0, key: key) }.map { _ = NSWorkspace.shared.open($0) } } label: { Text(key) }
                .disabled(jira.site == nil)
                .help(jira.site == nil ? "Set up Jira in Settings to open the ticket" : "Open \(key) in Jira")
        }
        if let address = topic.pullRequestURL, let url = URL(string: address) {
            Button { NSWorkspace.shared.open(url) } label: { Label(AgentSessions.shortReference(address), systemImage: "arrow.triangle.pull") }
                .help("Open the pull request this session is for")
        }
        if let url = topic.slackURL.flatMap(URL.init(string:)) {
            Button { NSWorkspace.shared.open(url) } label: { Label("Thread", systemImage: "arrow.up.forward.square") }
                .help("Open the Slack thread")
        }
        if !topic.linked.isEmpty { AgentSetChips(topic: topic) }
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: topic.folder)]) } label: { Image(systemName: "folder") }
            .buttonStyle(.borderless)
            .help("\(topic.importedSession == nil ? "The agent\u{2019}s own folder" : "The session\u{2019}s folder"): \((topic.folder as NSString).abbreviatingWithTildeInPath)")
    }
}

struct AgentTopicIcon: View {
    let kind: TopicAgent.Kind

    var body: some View {
        switch kind {
        case .ticket: BrandMark.jira.resizable().scaledToFit().frame(width: 12, height: 12)
        case .slack: BrandMark.slack.resizable().scaledToFit().frame(width: 12, height: 12)
        case .pullRequests: Image(systemName: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
        case .topic: Image(systemName: "text.bubble").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The New agent sheet: a name, and optionally the Jira ticket and Slack thread the topic is about.
struct NewTopicAgentSheet: View {
    @State var name = ""
    @State var jira = ""
    @State var slack = ""
    @State var problem: String?
    var store = TopicAgentStore.shared
    let done: (TopicAgent?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Agent").font(.headline)
            Text("An agent for a support case or any other topic, working in its own folder rather than a repository. It reads the "
                 + "linked ticket and thread, and drafts replies for you to post.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("Name", text: $name, prompt: "Support: Intrum UAT", hint: nil)
            field("Jira ticket", text: $jira, prompt: "ISD-123 (optional)",
                  hint: jira.trimmingCharacters(in: .whitespaces).isEmpty || JiraLogic.issueKey(jira) != nil ? nil : "Not a key like ISD-123")
            field("Slack thread", text: $slack, prompt: "https://acme.slack.com/archives/C0123/p1700000000123456 (optional)",
                  hint: slack.trimmingCharacters(in: .whitespaces).isEmpty || SlackLogic.threadLink(slack) != nil ? nil : "Not a Slack message link")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
            if let hint { Text(hint).font(.caption).foregroundStyle(.red) }
        }
    }

    private func create() {
        guard jira.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || LinkTargets.jira(jira) != nil else {
            problem = TopicAgentError.badJiraKey(jira).message
            return
        }
        let thread = SlackLogic.threadLink(slack)
        guard slack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || thread != nil else {
            problem = TopicAgentError.badSlackLink(slack).message
            return
        }
        let links = [LinkTargets.jira(jira), thread.map { LinkEntity.slack($0.url) }].compactMap { $0 }
        switch store.choose(links) {
        case .existing(let key):
            done(nil)
            store.openExisting(key, links: links)
            return
        case .cancel: return
        case .create: break
        }
        switch store.make(name: name, jira: jira, slack: slack) {
        case .success(let topic): done(topic)
        case .failure(let error): problem = error.message
        }
    }
}
