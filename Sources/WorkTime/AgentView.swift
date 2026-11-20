import AppKit
import SwiftUI

/// The Main page of the main window: every agent in a list beside the one picked. Main lives for the whole run of the app,
/// so its transcript stays when the page or the window goes away.
@MainActor
final class AgentHub: ObservableObject {
    static let shared = AgentHub()

    static let lastMainKey = "agentLastMain"

    /// Each workspace's Main by its id.
    private(set) var mains: [String: AgentModel]
    @Published var selected: String {
        didSet { if Workspaces.isMainKey(selected) { UserDefaults.standard.set(selected, forKey: Self.lastMainKey) } }
    }

    /// Set by the main window: brings it forward on the Main page.
    var showPage: (() -> Void)?

    init(workspaces: [Workspace]? = nil) {
        let workspaces = workspaces ?? WorkspaceStore.shared.workspaces
        WorkspaceDefaults.migrate()
        let made = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, AgentModel(main: $0)) })
        let last = UserDefaults.standard.string(forKey: Self.lastMainKey).flatMap(Workspaces.id(ofMainKey:))
        mains = made
        selected = Workspaces.mainKey(last.flatMap { made[$0] == nil ? nil : $0 } ?? workspaces.first?.id ?? Workspaces.defaultID)
    }

    /// A workspace made while the app runs gets its Main at once.
    func addMain(for workspace: Workspace) {
        guard mains[workspace.id] == nil else { return }
        mains[workspace.id] = AgentModel(main: workspace)
        objectWillChange.send()
    }

    var isMainSelected: Bool { Workspaces.isMainKey(selected) }

    var selectedMain: AgentModel? { Workspaces.id(ofMainKey: selected).flatMap { mains[$0] } }

    /// The Main last shown, or the first workspace's.
    var currentMainKey: String { isMainSelected ? selected : UserDefaults.standard.string(forKey: Self.lastMainKey) ?? Workspaces.mainKey(Workspaces.defaultID) }

    func show(_ key: String? = nil) {
        showExact(key.map { PullRequestSets.route($0, in: TopicAgentStore.shared.topics) } ?? currentMainKey)
    }

    func showExact(_ key: String) {
        selected = key
        showPage?()
    }

    /// Opens a session at an item of its transcript, as the timeline of a ticket or pull request does.
    func jump(to session: String, item: String?) {
        show(session)
        guard let item else { return }
        if TopicAgents.isKey(session), let topic = TopicAgentStore.shared.topic(session) {
            TopicAgentStore.shared.load(topic).jump(to: item)
        } else if let target = GitHubLink.pullRequest(at: session) {
            Task { @MainActor in await PRAgents.shared.load(target).jump(to: item) }
        }
    }
}

enum AgentListWidth {
    static let key = "agentListWidth"
    static let standard = 250.0
    static let range = 240.0...600.0

    static func clamped(_ width: Double) -> Double { min(max(width, range.lowerBound), range.upperBound) }
}

struct AgentsPage: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject private var writer = AgentStateWriter.shared
    @ObservedObject private var topics = TopicAgentStore.shared
    @ObservedObject private var assistants = AssistantStore.shared
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var handoffs = SpaceHandoffCenter.shared
    @AppStorage("agentListHidden") private var listHidden = false
    @AppStorage(AgentListWidth.key) private var listWidth = AgentListWidth.standard
    @State private var dragStart: Double?
    @State private var search = AgentSearchField()

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                AgentList(hub: hub, groups: Workspaces.groups(writer.states(), file: workspaces.file,
                                                              lastUsed: AgentSessions.lastUsed(AgentSessionStore.all())), search: $search)
                    .frame(width: AgentListWidth.clamped(listWidth))
                Divider()
                    .overlay(Color.clear.frame(width: 8).contentShape(Rectangle()).onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? AgentListWidth.clamped(listWidth)
                            dragStart = start
                            listWidth = AgentListWidth.clamped(start + drag.translation.width)
                        }
                        .onEnded { _ in dragStart = nil }))
            }
            Group {
                if let main = hub.selectedMain {
                    AgentView(model: main, listHidden: $listHidden)
                } else if SessionSubject.isKey(hub.selected) {
                    TicketTimelinePage(id: hub.selected, listHidden: $listHidden)
                } else if TopicAgents.isKey(hub.selected) {
                    AgentTopicPage(key: hub.selected, listHidden: $listHidden)
                } else if Assistants.isKey(hub.selected) {
                    AgentAssistantPage(key: hub.selected, listHidden: $listHidden)
                } else if Routines.isKey(hub.selected) {
                    AgentRoutinePage(key: hub.selected, listHidden: $listHidden)
                } else {
                    AgentPRPage(key: hub.selected, listHidden: $listHidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { hub.selectedMain?.loadFiles() }
        .onReceive(NotificationCenter.default.publisher(for: AgentSearch.openRequested)) { _ in
            listHidden = false
            search.open()
        }
        .sheet(item: $handoffs.pending) { handoff in SpaceHandoffSheet(handoff: handoff) { handoffs.pending = nil } }
    }
}

/// The agents by workspace, each group with its Main first, then the pull requests' and topics' agents, the ones that need you first.
struct AgentList: View {
    @ObservedObject var hub: AgentHub
    @ObservedObject private var linkStore = LinkStore.shared
    let groups: [Workspaces.Group]
    @Binding var search: AgentSearchField
    @FocusState private var searchFocused: Bool
    @ObservedObject var topics = TopicAgentStore.shared
    @ObservedObject var assistants = AssistantStore.shared
    @ObservedObject var workspaces = WorkspaceStore.shared
    @AppStorage(Workspaces.selectedKey) private var filter = Workspaces.allChoice
    @AppStorage(Workspaces.collapsedKey) private var collapsed = ""
    @AppStorage(Assistants.collapsedKey) private var collapsedAssistants = ""
    @AppStorage(Spaces.selectedKey) private var chosenSpaces = ""
    @ObservedObject private var routines = RoutineStore.shared
    @State var creating = false
    @State private var importing = false
    @State private var deleting: TopicAgent?
    @State private var assistantAction: AssistantAction?
    @State private var deletingAssistant: AssistantEntry?

    var body: some View {
        let now = Date()
        let query = search.isOpen ? search.query : ""
        VStack(spacing: 0) {
            if search.isOpen { searchField(query: query) }
            if groups.count > 1 { switcher }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleGroups, id: \.workspace.id) { group in
                        groupHeader(group)
                        if !collapsedIDs.contains(group.workspace.id) {
                            let space = Spaces.chosen(chosenSpaces, workspace: group.workspace.id, in: group.workspace.spaces)
                            if !group.workspace.spaces.isEmpty { spaceChips(group, selected: space) }
                            if let main = group.main, AgentSearch.filter([main], query: query, titles: prTitles).count == 1 { rowButton(main, now: now) }
                            assistantSection(group, space: space, now: now, query: query)
                            RoutineSection(workspace: group.workspace, hub: hub, space: space, query: query)
                            RoutineSection(workspace: group.workspace, hub: hub, automations: true, space: space, query: query)
                            AgentsSection(workspace: group.workspace, agents: group.agents, titles: prTitles, space: space, query: query, onNew: { creating = true }) { rowButton($0, now: now) } group: { ticketGroup($0, workspace: group.workspace) }
                        }
                    }
                }
                .padding(8)
            }
            Divider()
            footer
        }
        .background(Color.primary.opacity(0.025))
        .task(id: visibleGroups.flatMap(\.agents).map(\.key)) {
            let refs = visibleGroups.flatMap { group in
                let projects = Set(group.workspace.jiraProjects.map { $0.uppercased() })
                return group.agents.compactMap { AgentListFilter.ref(of: $0, projects: projects, titles: prTitles) }
            }
            await SessionRefDirectory.shared.ensure(refs, skip: [])
        }
        .sheet(isPresented: $creating) {
            NewTopicAgentSheet { topic in
                creating = false
                if let topic { hub.selected = topic.key }
            }
        }
        .sheet(isPresented: $importing) { ImportClaudeSessionSheet { importing = false } }
        .assistantSheets(action: $assistantAction, deleting: $deletingAssistant) { hub.selected = $0 }
        .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete Agent and Folder", role: .destructive) {
                if let deleting { topics.delete(deleting.key) }
            }
        } message: {
            if deleting?.importedSession != nil {
                Text("Removes the agent from the list. Its folder and Claude Code\u{2019}s session transcripts are kept.")
            } else if deleting?.assistant != nil {
                Text("Removes the session from the list. The assistant\u{2019}s folder and Claude Code\u{2019}s session transcripts are kept.")
            } else {
                Text("Removes the agent from the list and deletes its folder \((deleting?.folder ?? "") as NSString).abbreviatingWithTildeInPath). "
                     + "Claude Code keeps its session transcripts.")
            }
        }
    }

    private func searchField(query: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search agents", text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { firstMatch(query: query).map { hub.selected = $0 } }
                .onExitCommand { search.close() }
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .onAppear { searchFocused = true }
        .onChange(of: search.focusTick) { searchFocused = true }
    }

    /// What Return opens: the first row shown, going down the list as it is laid out.
    private func firstMatch(query: String) -> String? {
        for group in visibleGroups {
            let space = Spaces.chosen(chosenSpaces, workspace: group.workspace.id, in: group.workspace.spaces)
            let main = AgentSearch.filter(group.main.map { [$0] } ?? [], query: query, titles: prTitles)
            let assistants = AgentSearch.filter(Spaces.filter(group.assistants, space: space), query: query, titles: prTitles)
            let routines = [false, true].flatMap { RoutineSection.shown(self.routines.routines(in: group.workspace.id), automations: $0, space: space, query: query) }
            let agents = AgentsSection<EmptyView, EmptyView>.scoped(group.agents, workspace: group.workspace, space: space, titles: prTitles, query: query, links: LinkStore.shared.searchIndex).filter { $0.archived != true }
            if let key = (main + assistants).map(\.key).first ?? routines.map(\.key).first ?? agents.map(\.key).first { return key }
        }
        return nil
    }

    private var prTitles: [String: String] {
        Dictionary(GitHubModel.shared.prs.values.joined().map { ($0.url, $0.title) }) { first, _ in first }
    }

    /// A ticket's or pull request's sessions under one row.
    private func ticketGroup(_ ticket: TicketGroup, workspace: Workspace) -> some View {
        TicketGroupView(group: ticket, titles: prTitles, select: { hub.selected = $0 }, openTimeline: { hub.selected = ticket.id },
                        spaceMenu: { AnyView(SpaceMenus(states: $0.live, spaces: workspace.spaces, subject: $0.subject, workspace: workspace.id)) }) { state in
            Button { hub.selected = state.key } label: { TicketMemberRow(state: state, selected: hub.selected == state.key) }
                .buttonStyle(.plain)
                .contextMenu { menu(state) }
        }
    }

    private func rowButton(_ state: AgentState, now: Date) -> some View {
        Button { hub.selected = state.key } label: { row(state, now: now) }
            .buttonStyle(.plain)
            .contextMenu { menu(state) }
    }

    private var collapsedAssistantIDs: Set<String> { Set(collapsedAssistants.split(separator: ",").map(String.init)) }

    /// The workspace's assistants, indented under its Main, with a menu to make one.
    @ViewBuilder
    private func assistantSection(_ group: Workspaces.Group, space: String?, now: Date, query: String) -> some View {
        let id = group.workspace.id, isCollapsed = collapsedAssistantIDs.contains(id) && !AgentSearch.isActive(query)
        let shown = AgentSearch.filter(Spaces.filter(group.assistants, space: space), query: query, titles: prTitles)
        if !AgentSearch.isActive(query) || !shown.isEmpty {
            HStack(spacing: 4) {
                Button {
                    var ids = collapsedAssistantIDs
                    if isCollapsed { ids.remove(id) } else { ids.insert(id) }
                    collapsedAssistants = ids.sorted().joined(separator: ",")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text("Assistants").font(.caption2.weight(.semibold))
                        Text("\(AgentSearch.isActive(query) ? shown.count : group.assistants.count)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show the assistants of \(group.workspace.name)" : "Hide the assistants of \(group.workspace.name)")
                Spacer()
                Menu {
                    NewAssistantMenuItems(workspace: id, action: $assistantAction) { hub.selected = $0 }
                } label: { Image(systemName: "plus").font(.caption) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New Assistant: a role agent under this workspace\u{2019}s Main, such as a developer or a time reporter")
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
            .padding(.top, 2)
        }
        if !isCollapsed {
            ForEach(shown, id: \.key) { state in
                Button { hub.selected = state.key } label: { assistantRow(state, now: now) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(state) }
            }
        }
    }

    private func assistantRow(_ state: AgentState, now: Date) -> some View {
        let need = AgentOverview.need(state)
        return HStack(spacing: 7) {
            Circle().fill(Self.color(need)).frame(width: 7, height: 7).help(need.label)
            AssistantIcon(name: assistants.entry(state.key)?.role.icon ?? Assistants.defaultIcon)
            Text(state.title).font(.callout).lineLimit(1)
            SpaceTags(ids: state.spaces, spaces: workspaces.spaces(of: state.workspace))
            Spacer(minLength: 4)
            if state.error != nil, state.status == .idle {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red).help(state.error ?? "")
            } else if need != .idle {
                Text(need.label).font(.caption2).foregroundStyle(Self.color(need)).lineLimit(1)
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hub.selected == state.key ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }

    private func spaceChips(_ group: Workspaces.Group, selected: String?) -> some View {
        let spaces = group.workspace.spaces, states = group.assistants + group.agents
        var waiting = Set(spaces.filter { Spaces.needsUser(states, space: $0.id) }.map(\.id))
        if Spaces.needsUser(states, space: nil) { waiting.insert(Spaces.all) }
        return SpaceChipRow(spaces: spaces, counts: Spaces.counts(states: states, routines: routines.routines(in: group.workspace.id), spaces: spaces),
                            waiting: waiting, selected: selected) { chosenSpaces = Spaces.choosing($0, workspace: group.workspace.id, in: chosenSpaces) }
    }

    private var visibleGroups: [Workspaces.Group] {
        groups.contains { $0.workspace.id == filter } ? groups.filter { $0.workspace.id == filter } : groups
    }

    private var collapsedIDs: Set<String> { Set(collapsed.split(separator: ",").map(String.init)) }

    private var switcher: some View {
        Picker("Workspace", selection: $filter) {
            Text("All").tag(Workspaces.allChoice)
            ForEach(groups, id: \.workspace.id) { Text($0.workspace.name).tag($0.workspace.id) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .onChange(of: filter) {
            guard let group = groups.first(where: { $0.workspace.id == filter }), !group.all.contains(where: { $0.key == hub.selected }) else { return }
            hub.selected = group.workspace.mainKey
        }
    }

    private func groupHeader(_ group: Workspaces.Group) -> some View {
        let id = group.workspace.id, isCollapsed = collapsedIDs.contains(id)
        return Button {
            var ids = collapsedIDs
            if isCollapsed { ids.remove(id) } else { ids.insert(id) }
            collapsed = ids.sorted().joined(separator: ",")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Image(systemName: group.workspace.symbol).foregroundStyle(group.workspace.tint)
                Text(group.workspace.name).font(.caption.weight(.semibold))
                Spacer()
                if group.needing > 0 {
                    Text("\(group.needing)").font(.caption2.weight(.semibold)).foregroundStyle(.orange).help("Agents that need you")
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Show \(group.workspace.name)" : "Hide \(group.workspace.name)")
    }

    private var footer: some View {
        HStack {
            Button { creating = true } label: { Label("New Agent", systemImage: "plus") }
                .help("An agent for a support case or other topic, linked to a Jira ticket or Slack thread")
            Spacer()
            Menu {
                Button("Import Claude Code Session\u{2026}") { importing = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            if !topics.archived.isEmpty {
                Menu {
                    ForEach(topics.archived) { topic in
                        Button("Unarchive \(topic.name)") { topics.setArchived(topic.key, false) }
                    }
                } label: { Image(systemName: "archivebox") }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("\(topics.archived.count) archived topic agent\(topics.archived.count == 1 ? "" : "s")")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func menu(_ state: AgentState) -> some View {
        if let session = state.sessionID,
           let folder = state.folder ?? AgentSessionStore.list(for: state.key).first(where: { $0.id == session })?.folder {
            Button("Open in Claude Code\u{2026}") { ClaudeSessionImporter.openInClaudeCode(folder: folder, session: session) }
        }
        Button("Copy session id") { state.sessionID.map { ClaudeSessionImporter.copy(sessionID: $0) } }
            .disabled(state.sessionID == nil)
        if let entry = assistants.entry(state.key) {
            Divider()
            AssistantMenuItems(entry: entry, action: $assistantAction, deleting: $deletingAssistant) { hub.selected = $0 }
        } else if !Workspaces.isMainKey(state.key) {
            SpaceMenus(states: [state], spaces: workspaces.spaces(of: state.workspace), subject: TicketGrouping.subject(of: state, projects: jiraProjects(of: state), titles: prTitles),
                       workspace: state.workspace ?? Workspaces.defaultID)
            Menu("Move to Workspace") {
                ForEach(workspaces.workspaces) { workspace in
                    Toggle(workspace.name, isOn: Binding { workspaces.assigned(state) == workspace.id } set: { _ in workspaces.move(state.key, to: workspace.id) })
                }
                Divider()
                Button("Automatic") { workspaces.move(state.key, to: nil) }
            }
        }
        if let topic = topics.topic(state.key) {
            Divider()
            if topic.archived { Button("Unarchive") { topics.setArchived(topic.key, false) } } else { Button("Archive") { topics.setArchived(topic.key, true) } }
            Button("Delete\u{2026}", role: .destructive) { deleting = topic }
        }
    }

    private func jiraProjects(of state: AgentState) -> Set<String> {
        Set((workspaces.workspace(state.workspace)?.jiraProjects ?? []).map { $0.uppercased() })
    }

    private func row(_ state: AgentState, now: Date) -> some View {
        let need = AgentOverview.need(state)
        let isMain = Workspaces.isMainKey(state.key)
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(Self.color(need)).frame(width: 8, height: 8).padding(.top, 5).help(need.label)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let topic = topics.topic(state.key) { AgentTopicIcon(kind: topic.kind) }
                    Text(isMain ? "Main" : Self.reference(state)).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    SpaceTags(ids: state.spaces, spaces: workspaces.spaces(of: state.workspace))
                    if let updated = state.updatedAt {
                        Text(GitHubLogic.updatedText(updated, now: now)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(isMain ? "Overview of \(workspaces.workspace(state.workspace)?.name ?? "everything")" : title(state)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if need != .idle {
                    Text(state.status == .signedOut ? "Signed out of Claude" : need.label).font(.caption2).foregroundStyle(Self.color(need))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hub.selected == state.key ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }

    static func color(_ need: AgentOverview.Need) -> Color {
        switch need {
        case .waiting: return .orange
        case .unseen: return .accentColor
        case .error: return .red
        case .working: return .green
        case .idle: return .secondary.opacity(0.4)
        }
    }

    private static func reference(_ state: AgentState) -> String {
        state.prURL.map(AgentSessions.shortReference) ?? state.title
    }

    private func title(_ state: AgentState) -> String {
        if state.isTopic {
            let agent = LinkEntity.agent(state.key)
            let legacy = topics.topic(state.key)?.linkTargets ?? []
            let pending = legacy.filter { linkStore.table.link(LinkPair(agent, $0)) == nil }
            let targets = Set(linkStore.table.neighbors(of: agent) + pending).sorted()
            let links = targets.compactMap { target -> String? in
                switch target.kind {
                case .jira: return target.id
                case .githubPR: return AgentOverview.prTitle(LinkTargets.pullRequestURL(target.id) ?? target.id)
                case .slackThread: return "Slack thread"
                default: return nil
                }
            }
            return links.isEmpty ? "Topic agent" : links.joined(separator: " \u{00B7} ")
        }
        let reference = state.prURL.map { AgentOverview.prTitle($0) } ?? state.title
        let rest = state.title.hasPrefix(reference) ? state.title.dropFirst(reference.count).trimmingCharacters(in: .whitespaces) : state.title
        return rest.isEmpty ? (state.loaded ? "Pull request agent" : "Saved session") : rest
    }
}

/// A pull request's agent on the Main page: the same model as beside the pull request, loaded when it is not yet.
struct AgentPRPage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var agents = PRAgents.shared

    var body: some View {
        if let model = agents.model(for: key) {
            AgentView(model: model, listHidden: $listHidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) {
                    if let target = GitHubLink.pullRequest(at: key) { _ = await agents.load(target) }
                }
        }
    }
}

struct AgentView: View {
    @ObservedObject var model: AgentModel
    var listHidden: Binding<Bool>?

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= AgentWorkMap.sideMinWidth
            VStack(alignment: .leading, spacing: 0) {
                header(wide: wide)
                Divider()
                AgentWorkMapSplit(model: model, wide: wide) { AgentPanel(model: model) }
            }
        }
        .frame(minWidth: 420, minHeight: 440)
    }

    private var isMain: Bool { model.isMain && model.prURL == nil }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 10) {
            if let listHidden {
                Button { listHidden.wrappedValue.toggle() } label: { Image(systemName: "sidebar.squares.left") }
                    .buttonStyle(.borderless)
                    .help(listHidden.wrappedValue ? "Show the agents" : "Hide the agents")
            }
            if let url = model.prURL, let pr = GitHubLink.pullRequest(at: url) {
                Label(AgentSessions.shortReference(url), systemImage: "arrow.triangle.pull").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    .help(url)
                Button { AgentModel.openAgentLink?(pr) } label: { Label("Open PR", systemImage: "arrow.up.forward.square") }
                    .help("Open the pull request page with this agent beside it")
            } else if let topic = model.topic {
                AgentTopicHeader(topic: topic)
            } else if let assistant = model.assistant {
                AgentAssistantHeader(entry: assistant)
            } else if let routine = model.routine {
                AgentRoutineHeader(routine: routine)
            } else {
                Text(isMain ? "Main" : "Agent").font(.system(size: 20, weight: .medium)).fixedSize()
                if isMain { MainWorkspaceBadge(workspace: model.workspace) }
                Button { model.chooseFolder() } label: {
                    Label((model.folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder").lineLimit(1).truncationMode(.head)
                }
                .buttonStyle(.borderless)
                .help("The folder the agent works in")
            }
            AgentWorktreeNote(folder: model.folder)
            Spacer()
            ViewThatFits(in: .horizontal) {
                controls(compact: false, wide: wide)
                controls(compact: true, wide: wide)
            }
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Icons only when the pane is too narrow for their titles, so the header never widens the transcript under it.
    private func controls(compact: Bool, wide: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if isMain {
                    Button { model.catchUp() } label: { Label("Catch up", systemImage: "sparkles") }
                        .disabled(model.busy)
                        .help(AgentLogic.catchUpPrompt)
                }
                AgentSessionsButton(model: model)
                AgentChromeToggle(model: model)
                AgentPermissionPicker(model: model)
                AgentSessionAllowButton(model: model)
            }
            .labelStyle(CompactLabelStyle(compact: compact))
            AgentModelPicker(model: model)
            AgentNewSessionButton(model: model).labelStyle(CompactLabelStyle(compact: compact))
            AgentWorkMapToggle(model: model, wide: wide).labelStyle(.iconOnly)
            AgentOverflowMenu(model: model)
        }
    }

    private struct CompactLabelStyle: LabelStyle {
        let compact: Bool

        func makeBody(configuration: Configuration) -> some View {
            if compact { Label(configuration).labelStyle(.iconOnly) } else { Label(configuration) }
        }
    }
}

/// The sessions of one agent: the current one, the earlier ones newest first, and those in its folder it has not had.
struct AgentSessionsButton: View {
    @ObservedObject var model: AgentModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { Label("Sessions", systemImage: "clock.arrow.circlepath") }
            .disabled(model.busy)
            .help(model.busy ? "Switch sessions when the agent has finished" : "Pick an earlier session")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AgentSessionList(model: model) { showing = false }
            }
    }
}

struct AgentSessionList: View {
    @ObservedObject var model: AgentModel
    @AppStorage(AgentProvider.claudeEnabledKey) private var claudeEnabled = true
    var done: () -> Void = {}
    @State var others: [AgentSessionEntry]?
    @State var showsOthers = false

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if model.sessionID == nil {
                    row(title: "New session", detail: "Not started yet", current: true) {}
                }
                ForEach(model.history) { entry in
                    row(title: entry.title, detail: detail(entry, now: now), current: model.provider == .claude && entry.id == model.sessionID) { pick(entry) }
                        .contextMenu {
                            Button("Remove from List") { model.forget(entry.id) }.disabled(model.provider == .claude && entry.id == model.sessionID)
                        }
                }
                Divider().padding(.vertical, 4)
                if showsOthers {
                    Text("Other sessions in this folder").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    if let others {
                        if others.isEmpty {
                            Text("None").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 8)
                        }
                        ForEach(others) { entry in
                            row(title: entry.title, detail: GitHubLogic.updatedText(entry.lastUsed, now: now), current: false) { pick(entry) }
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    }
                } else {
                    Button("Show All Sessions in This Folder") {
                        showsOthers = true
                        Task { others = await model.otherSessions() }
                    }
                    .linkButtonStyle()
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .help("Find Claude sessions in this folder")
                }
            }
            .padding(8)
        }
        .frame(width: 340)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pick(_ entry: AgentSessionEntry) {
        done()
        if claudeEnabled { model.switchTo(entry) } else { model.viewingHistory = entry }
    }

    private func detail(_ entry: AgentSessionEntry, now: Date) -> String {
        let cost = UsageStore.shared.cost(session: entry.id).map { UsageDisplay.current().money($0) }
        return ([GitHubLogic.updatedText(entry.lastUsed, now: now)] + [entry.model.map(AgentLogic.modelName), cost].compactMap { $0 })
            .joined(separator: " \u{00B7} ")
    }

    private func row(title: String, detail: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).opacity(current ? 1 : 0).padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.tail)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(claudeEnabled ? "Open this session" : "View the saved transcript")
    }
}

private struct AgentHistoryReader: View {
    let entry: AgentSessionEntry
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AgentItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.title).font(.headline).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let model = entry.model { Text(AgentLogic.modelName(model)).foregroundStyle(.secondary) }
            Divider()
            if let items {
                if items.isEmpty { Text("No saved messages were found for this session.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            AgentItemRow(item: item, folder: entry.folder, answer: { _, _, _ in }, move: { _ in })
                        }
                    }
                }
            } else { ProgressView("Loading saved transcript…") }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 700, minHeight: 380, idealHeight: 550, alignment: .topLeading)
        .task(id: entry.id) {
            let entry = entry
            let loaded = await Task.detached(priority: .userInitiated) {
                AgentTranscript.savedItems(sessionID: entry.id, folder: entry.folder)
            }.value
            if !Task.isCancelled { items = loaded }
        }
    }
}

struct AgentModelPicker: View {
    @ObservedObject var model: AgentModel
    @StateObject private var codexSetup = CodexSetupModel()
    @AppStorage(AgentProvider.claudeEnabledKey) private var claudeEnabled = true
    @AppStorage(AgentProvider.codexEnabledKey) private var codexEnabled = true

    var body: some View {
        let selected = model.modelChoice
        let codexModels = CodexSetup.models(codexSetup.models, including: selected.provider == .codex ? selected.model : nil)
        Picker("Model", selection: Binding(get: { model.modelChoice }, set: model.chooseModel)) {
            if claudeEnabled {
                Section("Claude") {
                    ForEach(AgentLogic.models, id: \.id) { claude in
                        Text(claude.name).tag(AgentModelChoice(provider: .claude, model: claude.id))
                    }
                }
            } else if selected.provider == .claude {
                Text(selected.model + " (disabled)").tag(selected)
            }
            if codexEnabled {
                Section("Codex") {
                    ForEach(codexModels) { codex in
                        Text(codex.name + (codex.isDefault ? " (default)" : "")).tag(AgentModelChoice(provider: .codex, model: codex.id))
                    }
                }
            } else if selected.provider == .codex {
                Text((selected.model.isEmpty ? "Codex default" : selected.model) + " (disabled)").tag(selected)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.busy || (!claudeEnabled && !codexEnabled))
        .task { codexSetup.refresh() }
        .help("Choose the provider and model for the next prompt. Switching provider starts its separate session.")
    }
}

struct AgentPermissionPicker: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Picker("Permissions", selection: Binding(get: { selectedMode }, set: { model.permissionMode = $0 })) {
            ForEach(AgentPermissionMode.allCases.filter { model.provider == .claude || $0 == .ask || $0 == .auto }) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Permissions: \(selectedMode.help)")
    }

    private var selectedMode: AgentPermissionMode {
        model.provider == .codex && model.permissionMode != .auto ? .ask : model.permissionMode
    }
}

/// Gives this agent the Claude in Chrome tools from the next prompt on; their actions ask in every mode, unless allowed for the session.
struct AgentChromeToggle: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Toggle(isOn: $model.chrome) {
            Label("Chrome", systemImage: model.chrome && model.chromeProblem != nil ? "exclamationmark.triangle" : "globe")
        }
        .toggleStyle(.button)
        .help(model.chromeProblem.map { "Claude in Chrome is not working: \($0)" }
              ?? (model.chrome ? "Claude in Chrome is on: the agent can use your Chrome through the extension. Reading tabs and pages "
                  + "runs without asking; navigating, clicking and typing ask, with Allow for this session or Always allow on the prompt." : "Let the agent use Chrome through the Claude in Chrome extension"))
    }
}

/// The calls allowed for the rest of this session, with Remove for each and Remove all; hidden when there are none.
struct AgentSessionAllowButton: View {
    @ObservedObject var model: AgentModel
    @State private var shown = false

    var body: some View {
        if !model.sessionAllowed.isEmpty {
            Button { shown.toggle() } label: { Label("\(model.sessionAllowed.count)", systemImage: "checkmark.shield") }
                .help("Allowed for this session: \(model.sessionAllowed.count)")
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed for this session").font(.headline)
                        ForEach(model.sessionAllowed, id: \.self) { key in
                            HStack {
                                Text(AgentRules.toolLabel(key)).font(.callout)
                                Spacer(minLength: 16)
                                Button("Remove") { model.revokeSession(key) }
                            }
                        }
                        if model.sessionAllowed.count > 1 {
                            Button("Remove all", role: .destructive) { model.revokeSession() }
                        }
                    }
                    .padding(12)
                }
        }
    }
}

struct AgentNewSessionButton: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        Button { model.newSession() } label: { Label("New Session", systemImage: "square.and.pencil") }
            .disabled(model.items.isEmpty && model.sessionID == nil)
            .help("New Session")
    }
}

/// The transcript, the permission prompts and the composer, in the Agent window and beside a pull request.
struct AgentPanel: View {
    @ObservedObject var model: AgentModel
    var gutter = RecordingDetail.gutter
    @State private var height: CGFloat = 26
    @State private var atBottom = true
    @State private var newBelow = false
    /// The block the timeline sent the user to, tinted for a moment.
    @State private var highlighted: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
            composer
        }
        .environment(\.openURL, OpenURLAction { model.open($0) })
        .sheet(item: $model.viewingHistory) { AgentHistoryReader(entry: $0) }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }

    private var isMain: Bool { model.isMain && model.prURL == nil }

    private func row(_ item: AgentItem) -> AgentItemRow {
        AgentItemRow(item: item, folder: model.folder, answer: { model.answer(item, allow: $0, always: $1, session: $2) },
                     addTool: { model.answer(item, allow: true, add: true) },
                     allowSite: { model.answer(item, allow: true, site: true) },
                     move: { if let folder = $0 { model.move(to: folder) } else { model.changeFolder() } })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.items.isEmpty {
                        if let latest = model.history.first {
                            Button { model.viewingHistory = latest } label: {
                                Label("View latest session: \(latest.title)", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        Text(isMain ? "Main keeps an eye on everything: pull requests, the agents beside them, Slack and meeting action items. "
                                + "Ask what needs you, or have it hand a prompt to a pull request\u{2019}s agent. It only reads unless you ask for more."
                             : model.assistant != nil ? "\(model.assistant?.role.summary ?? "") It follows the instructions in its Markdown file "
                                + "(Edit instructions, above); Main can hand it work, and it cannot post to Jira, Slack or GitHub."
                             : model.routine != nil ? "This routine runs its prompt on a schedule while WorkTime is open, in a fresh session each time. "
                                + "Run now starts one; earlier runs are under Sessions. Calls that need approval are refused when nobody is here."
                             : model.topic != nil ? "This agent works on one topic in its own folder. It reads the linked Jira ticket and Slack "
                                + "thread and searches both, and drafts replies for you to copy; it cannot post anywhere."
                             : "Ask the agent to read, search or change code in this folder. Type @ to reference a file. Edits and commands ask first.")
                            .foregroundStyle(.secondary)
                        if isMain {
                            Button { model.catchUp() } label: { Label("Catch up", systemImage: "sparkles") }
                                .buttonStyle(.borderedProminent)
                                .help(AgentLogic.catchUpPrompt)
                        }
                    }
                    ForEach(AgentToolGroups.blocks(model.items, unattended: model.routine != nil)) { block in
                        Group {
                            switch block {
                            case .item(let item): row(item)
                            case .tools(_, let items, let label): AgentToolGroup(label: label, items: items, row: row)
                            case .refused(_, let items, let label): AgentToolGroup(label: label, items: items, row: row, icon: "xmark.circle")
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(highlighted == block.id ? Color.accentColor.opacity(0.14) : .clear))
                    }
                    if isMain { TicketAskCards(workspace: model.workspace) }
                    if !model.busy, !model.blocked.isEmpty {
                        BlockedCard(calls: model.blocked, fixed: model.blockedFixed, apply: { model.apply($0, to: $1) },
                                    fixAndContinue: model.fixAndContinue, dismiss: model.dismissBlocked)
                    }
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                    if let problem = model.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if model.chrome, let problem = model.chromeProblem {
                        Label("Claude in Chrome is not connected: \(problem)", systemImage: "globe")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, gutter)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .transcriptTypography()
            .environment(\.agentActions, model.actionContext)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height - 40 } action: { _, bottom in
                atBottom = bottom
                if bottom { newBelow = false }
            }
            .onChange(of: model.items) {
                let sent = if case .user = model.items.last?.kind { true } else { false }
                if model.jumpRequest != nil { return jump(proxy) }
                if atBottom || sent { proxy.scrollTo("end", anchor: .bottom) } else { newBelow = true }
            }
            .onChange(of: model.jumpRequest) { jump(proxy) }
            .onAppear { jump(proxy) }
            .overlay(alignment: .bottom) {
                if newBelow {
                    Button { proxy.scrollTo("end", anchor: .bottom) } label: { Label("Jump to latest", systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .clipShape(Capsule())
                        .padding(.bottom, 10)
                }
            }
            .id(identity)
            .onChange(of: identity) {
                atBottom = true
                newBelow = false
            }
        }
    }

    /// Scrolls to the item the timeline asked for, once the transcript has it, and tints it for a moment.
    private func jump(_ proxy: ScrollViewProxy) {
        guard let request = model.jumpRequest else { return }
        guard let id = AgentToolGroups.blockID(containing: request.item, in: model.items, unattended: model.routine != nil) else { return }
        model.jumpHandled()
        atBottom = false
        proxy.scrollTo(id, anchor: .center)
        highlighted = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if highlighted == id { highlighted = nil }
        }
    }

    /// A new scroll view, which starts at the bottom, for each agent and each replaced transcript.
    private var identity: TranscriptIdentity { TranscriptIdentity(model: ObjectIdentifier(model), revision: model.transcriptRevision) }

    private struct TranscriptIdentity: Hashable {
        let model: ObjectIdentifier
        let revision: Int
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.mentionMatches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.mentionMatches, id: \.self) { path in
                        Button { model.draft = AgentLogic.insertMention(path, into: model.draft) } label: {
                            Label(path, systemImage: "doc.text")
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(path == model.mentionMatches.first ? Color.primary.opacity(0.07) : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background).shadow(radius: 2))
            } else if model.draft.isEmpty && model.items.isEmpty {
                HStack {
                    ForEach(isMain || model.topic != nil || model.assistant != nil || model.routine != nil ? [] : AgentLogic.quickActions, id: \.title) { action in
                        Button(action.title) { model.draft = action.prompt }.buttonStyle(SuggestionStyle())
                    }
                }
            }
            AgentPendingList(model: model).transcriptTypography()
            AgentImageChips(model: model)
            HStack(alignment: .bottom, spacing: 10) {
                ChatComposer(text: $model.draft, height: $height, placeholder: model.busy ? "Queue a follow-up message" : "Ask the agent \u{2014} @ to reference a file or paste an image",
                             attach: model.attach, problem: model.imageProblem) { model.submit() }
                    .transcriptTypography()
                    .frame(height: height)
                let hasContent = !model.draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.images.isEmpty
                if model.busy {
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 24)).foregroundStyle(Color.accentColor) }
                        .buttonStyle(.plain)
                        .help("Stop")
                }
                if !model.busy || hasContent {
                    Button { model.send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(hasContent ? Color.accentColor : .secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(model.busy ? "Queue message (Return)" : "Send (Return)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, max(gutter - 14, 6))
        .padding(.bottom, 16)
    }
}

struct AgentItemRow: View {
    let item: AgentItem
    let folder: String
    let answer: (_ allow: Bool, _ always: Bool, _ session: Bool) -> Void
    /// Puts the tool a permission card asks about on the assistant's list.
    var addTool: () -> Void = {}
    /// Allows the website a Claude in Chrome card names, for every agent.
    var allowSite: () -> Void = {}
    /// Moves the agent to the folder, or asks for one when nil.
    let move: (String?) -> Void
    @Environment(\.transcriptTypography) private var typography

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                if let message = AgentInbox.fromMain(text) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("From Main" + (AgentInbox.origin(of: text).map { " \u{00B7} \($0)" } ?? ""), systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.purple)
                        Text(message).lineSpacing(typography?.lineSpacing ?? 0).textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.12)))
                    .help("Sent by another agent, approved by you there or by clicking an action")
                } else if let report = AgentReports.parse(text) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("From \(report.from)", systemImage: "tray.and.arrow.down").font(.caption.weight(.medium)).foregroundStyle(.teal)
                        Text(report.text).lineSpacing(typography?.lineSpacing ?? 0).textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.12)))
                    .help("A report from another agent: information for Main, not you speaking. You approved it, or allowed the tool.")
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if !item.images.isEmpty {
                            HStack(spacing: 6) { ForEach(item.images, id: \.self) { AgentThumbnail(path: $0, side: 96) } }
                        }
                        if !text.isEmpty {
                            Text(text)
                                .lineSpacing(typography?.lineSpacing ?? 0)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                }
            }
            .transcriptPullRequests(in: text)
        case .text(let text):
            AgentReply(text: text) { AgentLogic.linkifiedCodeReferences($0, cwd: folder) { FileManager.default.fileExists(atPath: $0) } }
                .transcriptPullRequests(in: text)
        case .tool(let name, let summary, let detail, let result, let isError, let auto, let rule):
            AgentToolRow(name: name, summary: summary, detail: detail, result: result, isError: isError, auto: auto, rule: rule,
                         decision: item.decision, repeats: item.repeats)
        case .permission(let tool, let summary, let detail, let offer, let allowed):
            AgentPermissionRow(tool: tool, summary: summary, detail: detail, offer: offer, allowed: allowed, answer: answer, addTool: addTool, allowSite: allowSite)
        case .status(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        case .signIn:
            Label(LocalizedStringKey(AgentLogic.signInMessage), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.callout)
                .textSelection(.enabled)
        case .missingFolder(let missing):
            VStack(alignment: .leading, spacing: 8) {
                Label(AgentFolders.missingMessage((missing as NSString).abbreviatingWithTildeInPath), systemImage: "folder.badge.questionmark")
                    .font(.callout).textSelection(.enabled)
                HStack {
                    Button("Choose Folder\u{2026}") { move(nil) }
                    if let parent = AgentFolders.worktreeParent(of: missing), FileManager.default.fileExists(atPath: parent) {
                        Button("Use \(URL(fileURLWithPath: parent).lastPathComponent)") { move(parent) }
                            .help("Continue the conversation in \((parent as NSString).abbreviatingWithTildeInPath)")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        }
    }
}

struct AgentToolGroup: View {
    let label: String
    let items: [AgentItem]
    let row: (AgentItem) -> AgentItemRow
    var icon = "checkmark.circle"
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: icon).foregroundStyle(.secondary)
                    Text(label).foregroundStyle(.secondary)
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) { ForEach(items) { row($0) } }.padding(.leading, 16)
            }
        }
    }
}

private struct AgentToolRow: View {
    let name: String
    let summary: String
    let detail: String
    let result: String?
    let isError: Bool
    let auto: Bool
    let rule: String?
    /// How the user answered the permission prompt, nil when it was never asked.
    var decision: Bool?
    var repeats = 1
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Image(systemName: result == nil ? "hourglass" : isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(isError ? Color.red : .secondary)
                    Text(AgentLogic.displayName(name)).fontWeight(.medium)
                    Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let decision {
                        chip(decision ? "Allowed" : repeats > 1 ? "Denied \u{00D7}\(repeats)" : "Denied")
                    }
                    if auto {
                        Text(rule == nil ? "auto" : "auto \u{00B7} rule")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help(rule.map { "Allowed without asking by your rule: \($0)" } ?? "Allowed without asking: a read-only command")
                    }
                }
                .font(.callout)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                AgentCode(text: [detail, result].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"), collapsedLines: AgentCode.previewLines)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

private struct AgentPermissionRow: View {
    let tool: String
    let summary: String
    let detail: String
    let offer: [AgentRule]
    let allowed: Bool?
    let answer: (_ allow: Bool, _ always: Bool, _ session: Bool) -> Void
    let addTool: () -> Void
    let allowSite: () -> Void

    private var role: AgentRule? { RoleTools.role(in: offer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(role.map { RoleTools.title(tool: tool, assistant: $0.workspaceName) } ?? "Allow \(AgentLogic.displayName(tool))?", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
            if tool == "Bash" {
                AgentCode(text: detail, font: .callout, maxHeight: AgentCode.lines(10, font: .callout), collapsedLines: AgentCode.previewLines)
            } else {
                if !summary.isEmpty {
                    Text(summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if !detail.isEmpty { AgentCode(text: detail) }
            }
            if let allowed {
                Text(allowed ? "Allowed" : "Denied").font(.caption).foregroundStyle(.secondary)
            } else {
                if let always = AgentRules.offer(offer) {
                    Text(always).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let warning = role.flatMap({ RoleTools.note(tool: tool, tier: RoleTools.tier(of: $0)) }) ?? AgentRules.warning(offer) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if role != nil {
                        Button("Add to its tools") { addTool() }
                            .buttonStyle(.borderedProminent)
                            .help("Puts the tool on the list in the assistant\u{2019}s file, so it may use it from now on")
                    }
                    Button("Allow once") { answer(true, false, false) }
                    if AgentRules.sessionOffered(tool: tool) {
                        Button("Allow for this session") { answer(true, false, true) }
                            .help("Runs this tool without asking until the agent is restarted")
                    }
                    if role == nil, offer.contains(where: { $0.kind != .site }) {
                        Button(AgentRules.offerButton(offer)) { answer(true, true, false) }
                            .help("Saved in Settings \u{203A} Agent, for every agent")
                    }
                    if let site = AgentChromeSites.site(in: offer) {
                        Button("Allow for \(site)") { allowSite() }
                            .help("Claude in Chrome runs without asking on this website, for every agent. Saved in Settings \u{203A} Agent")
                    }
                    Button("Deny") { answer(false, false, false) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(allowed == nil ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1)))
    }
}

/// The calls the user chose to always allow, with Remove for each and Remove all.
struct AgentSettingsSection: View {
    @ObservedObject var store: AgentRuleStore
    @AppStorage(AgentPermissionMode.defaultKey) private var defaultMode = AgentPermissionMode.ask
    @AppStorage(AgentLogic.defaultModelKey) private var defaultModel = AgentLogic.builtInModel
    @AppStorage(AgentProvider.key) private var provider = AgentProvider.claude
    @AppStorage(AgentProvider.codexModelKey) private var codexModel = ""
    @AppStorage(AgentProvider.claudeEnabledKey) private var claudeEnabled = true
    @AppStorage(AgentProvider.codexEnabledKey) private var codexEnabled = true
    @AppStorage(AgentLogic.chromeDefaultKey) private var chromeByDefault = false
    @AppStorage(AgentLogic.chromeAllowAllKey) private var chromeAllowAll = false
    @AppStorage(AgentAttention.settingKey) private var notifyAttention = true
    @AppStorage(Decisions.keepKey) private var keepDecisions = true
    @AppStorage(Decisions.dropDownKey) private var dropDownDecisions = true
    @AppStorage(RoleTools.waitKey) private var roleWaitMinutes = RoleTools.defaultWaitMinutes
    @State private var alertWarning: String?
    @AppStorage(Automations.enabledKey) private var automationsOn = true
    @State private var confirming: String?
    @StateObject private var codexSetup = CodexSetupModel()
    @AppStorage(Determinism.autoAnalyzeKey) private var autoAnalyze = true
    @AppStorage(Determinism.fullRunEveryKey) private var fullRunEvery = Determinism.defaultFullRunEvery
    @AppStorage(TranscriptTypography.faceKey) private var transcriptFace = TranscriptTypography.standard.face.rawValue
    @AppStorage(TranscriptTypography.sizeKey) private var transcriptSize = TranscriptTypography.standard.size
    @AppStorage(TranscriptTypography.lineSpacingKey) private var transcriptLineSpacing = TranscriptTypography.standard.lineSpacing
    @AppStorage(TranscriptTypography.paragraphSpacingKey) private var transcriptParagraphSpacing = TranscriptTypography.standard.paragraphSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WorkspacesSettings()
            sections
        }
        .task { await refreshAlertStyle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAlertStyle() }
        }
        .onChange(of: claudeEnabled) { _, _ in moveDefaultProvider() }
        .onChange(of: codexEnabled) { _, _ in moveDefaultProvider() }
    }

    private func refreshAlertStyle() async {
        let current = await Permissions.notificationAlert
        alertWarning = Decisions.styleWarning(current.style, authorized: current.authorized)
    }

    private func moveDefaultProvider() {
        guard !AgentProvider.enabled(provider) else { return }
        guard let next = AgentProvider.allCases.first(where: { AgentProvider.enabled($0) }) else { return }
        let selected = AgentModelChoice(provider: provider, model: provider == .claude ? defaultModel : codexModel)
        guard let equivalent = AgentLogic.equivalent(selected, to: next) else { return }
        provider = next
        if next == .claude { defaultModel = equivalent.model } else { codexModel = equivalent.model }
    }

    private var transcriptTypography: TranscriptTypography {
        .make(face: transcriptFace, size: transcriptSize, lineSpacing: transcriptLineSpacing, paragraphSpacing: transcriptParagraphSpacing)
    }

    @ViewBuilder private var transcriptSection: some View {
        SettingsSection("Transcript text", footer: "The typeface and spacing of what agents and chats say. Code stays monospaced.") {
            SettingsRow("Typeface") {
                Picker("Typeface", selection: $transcriptFace) {
                    ForEach(TranscriptFace.available) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Size", detail: "\(Int(transcriptTypography.size)) pt") {
                Stepper("Size", value: $transcriptSize, in: TranscriptTypography.sizes, step: 1).labelsHidden()
            }
            SettingsRow("Line spacing", detail: "\(Int(transcriptTypography.lineSpacing)) pt between lines") {
                Stepper("Line spacing", value: $transcriptLineSpacing, in: TranscriptTypography.lineSpacings, step: 1).labelsHidden()
            }
            SettingsRow("Paragraph spacing", detail: "\(Int(transcriptTypography.paragraphSpacing)) pt between paragraphs") {
                Stepper("Paragraph spacing", value: $transcriptParagraphSpacing, in: TranscriptTypography.paragraphSpacings, step: 1).labelsHidden()
            }
            SettingsRow("Defaults", detail: "\(TranscriptTypography.standard.face.title), \(Int(TranscriptTypography.standard.size)) pt") {
                Button("Reset") { resetTranscript() }.disabled(transcriptTypography == .standard)
            }
            AnswerText(text: Self.transcriptSample)
                .environment(\.transcriptTypography, transcriptTypography)
                .font(transcriptTypography.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private static let transcriptSample = """
        ## Two things are still open

        The **Reviewer** found two blockers in the pull request. The cleanup deletes every announcement after 7 days, and the title goes into the e-mail unescaped.

        - Fix the cleanup so pinned ones stay
        - Escape the title before it is rendered
        1. Push the fix
        2. Ask for another review

        `let retention = 7`
        """

    private func resetTranscript() {
        let standard = TranscriptTypography.standard
        transcriptFace = standard.face.rawValue
        transcriptSize = standard.size
        transcriptLineSpacing = standard.lineSpacing
        transcriptParagraphSpacing = standard.paragraphSpacing
    }

    @ViewBuilder private var sections: some View {
        AssistantSessionSettings()
        SettingsSection("Model", footer: nil) {
            SettingsRow("Enable Claude", detail: "Uses the Claude Agent SDK and your Claude sign-in.") {
                Toggle("Enable Claude", isOn: $claudeEnabled).labelsHidden()
            }
            Divider().padding(.leading, 14)
            SettingsRow("Enable Codex", detail: "Uses local Codex App Server and your ChatGPT/Codex sign-in.") {
                Toggle("Enable Codex", isOn: $codexEnabled).labelsHidden()
            }
            if !claudeEnabled && !codexEnabled {
                Divider().padding(.leading, 14)
                SettingsRow("No coding agents enabled", detail: "Enable Claude or Codex above before starting an agent.") {}
            }
            Divider().padding(.leading, 14)
            SettingsRow("Coding agent", detail: provider.help) {
                Picker("Coding agent", selection: $provider) {
                    ForEach(AgentProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            if provider == .codex {
                Divider().padding(.leading, 14)
                SettingsRow("Codex", detail: codexDetail) {
                    Button("Check again", action: codexSetup.refresh).disabled(codexSetup.checking)
                    if case .missing = codexSetup.status { Button("Copy install command", action: codexSetup.copyInstallCommand) }
                    if case .signedOut = codexSetup.status { Button("Copy login command", action: codexSetup.copyLoginCommand) }
                    if case .signedIn = codexSetup.status { Button("Copy switch account command", action: codexSetup.copySwitchAccountCommand) }
                }
                .onAppear(perform: codexSetup.refresh)
                Divider().padding(.leading, 14)
                SettingsRow("Codex model", detail: "Available from the active account. WorkTime uses Codex's default when unset.") {
                    Picker("Codex model", selection: $codexModel) {
                        ForEach(CodexSetup.models(codexSetup.models, including: codexModel)) { model in
                            Text(model.name + (model.isDefault ? " (default)" : "")).tag(model.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            SettingsRow("Default model", detail: "Used by agents and roles that do not set their own model.") {
                Picker("Default model", selection: Binding(get: { AgentLogic.savedDefaultModel(defaultModel) }, set: { defaultModel = $0 })) {
                    ForEach(AgentLogic.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        SettingsSection("Permissions", footer: "How new agents start. An agent you already changed keeps its own, and assistants and routines keep theirs.") {
            SettingsRow("Default mode", detail: defaultMode.help) {
                Picker("Default mode", selection: $defaultMode) {
                    ForEach(AgentPermissionMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Claude in Chrome", detail: "Start new agents with the browser tools on. Switch it per agent with the Chrome button.") {
                Toggle("Claude in Chrome", isOn: $chromeByDefault).labelsHidden()
            }
            SettingsRow("Allow all Claude in Chrome actions", detail: "Lets agents click, type, navigate and run scripts in your real Chrome without asking, in every permission mode. Applies to all agents.") {
                Toggle("Allow all Claude in Chrome actions", isOn: $chromeAllowAll).labelsHidden()
            }
            ChromeSitesRows()
        }
        transcriptSection
        SettingsSection("Notifications", footer: "A system notification when an agent you are not looking at needs approval for a call or ends on a question. "
                        + "Allow once, Deny and Reply work from the notification, and so do Add to its tools, for a tool an assistant\u{2019}s file leaves out, and Fix and continue, after refusals. Routines never ask, except about a missing tool. A decision, such as an automation\u{2019}s question or "
                        + "an approval, stays until you answer: macOS must show WorkTime\u{2019}s notifications as Alerts for one to stay on screen.") {
            SettingsRow("Notify when an agent needs me") { Toggle("Notify when an agent needs me", isOn: $notifyAttention).labelsHidden() }
            SettingsRow("Keep decisions on screen", detail: "A decision whose notification was swept away comes back quietly after 10 and 30 minutes and an hour.") {
                Toggle("Keep decisions on screen", isOn: $keepDecisions).labelsHidden()
            }
            SettingsRow("Drop down the notch for decisions", detail: "When one starts waiting and you are in none of WorkTime\u{2019}s windows, the notch bar opens on it and stays open until you have answered or closed it.") {
                Toggle("Drop down the notch for decisions", isOn: $dropDownDecisions).labelsHidden()
            }
            SettingsRow("Routines wait for a missing tool", detail: "A routine whose assistant calls a tool its file leaves out waits this long for your answer (Add to its tools, Allow once or Deny) with its session open, then goes on without the tool and asks again after the run. An agent you work with waits for as long as you take.") {
                Picker("Routines wait for a missing tool", selection: $roleWaitMinutes) {
                    ForEach([5, 15, 30, 60, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Notification style", detail: alertWarning ?? "Alerts: a decision stays on screen until you answer.") {
                Button("Open Notification Settings") { Permissions.openNotificationSettings() }
            }
        }
        QuickChatSettings()
        UsageSettings()
        PromptTemplatesSettings()
        SettingsSection("Automations", footer: "Automations run an agent when something happens in Slack, GitHub or Jira. Off, none runs and none searches. "
                        + "Turned on again they start from what is there, so nothing that happened meanwhile runs.") {
            SettingsRow("Run automations") { Toggle("Run automations", isOn: $automationsOn).labelsHidden() }
        }
        SettingsSection("Routines", footer: "A routine can run partly or wholly as a script of read-only calls instead of the model. A script that fails makes the agent do the run, "
                        + "and now and then the agent runs in full so the script can be checked against it.") {
            SettingsRow("Look for a script after a run", detail: "The agent looks at a routine's first successful run for parts a script could do, once, and proposes it. You decide.") {
                Toggle("Look for a script after a run", isOn: $autoAnalyze).labelsHidden()
            }
            SettingsRow("Run the agent in full every", detail: "How often a routine with a script is run by the agent anyway. 0 for never.") {
                Stepper(value: $fullRunEvery, in: 0...100) { Text(fullRunEvery == 0 ? "never" : "\(fullRunEvery) runs") }.fixedSize()
            }
        }
        SettingsSection("Always allowed", footer: "Saved with Always allow on a permission prompt and used by every agent. A command is "
                        + "allowed when each part that is not read-only starts with one of these. Claude in Chrome\u{2019}s actions are allowed one tool at a time (a click, typing and the like one computer action at a time). Tools that ask by default are listed below; Main\u{2019}s send to agent asks unless you allowed it to message that agent.") {
            if store.rules.isEmpty {
                SettingsRow("Nothing yet", detail: "Choose Always allow when an agent asks to run something") {}
            }
            ForEach(Array(store.rules.enumerated()), id: \.element) { index, rule in
                if index > 0 { Divider().padding(.leading, 14) }
                SettingsRow(AgentRules.label(rule), detail: AgentRules.warning([rule]).map { _ in rule.kind == .tool ? AgentRules.riskNote(rule.value) : "Runs with any arguments, also destructive ones" }) {
                    if AgentRules.warning([rule]) != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Remove") { store.remove(rule) }
                }
            }
            if store.rules.count > 1 {
                Divider().padding(.leading, 14)
                SettingsRow("\(store.rules.count) rules") {
                    Button("Remove all", role: .destructive) { store.removeAll() }
                }
            }
            Divider().padding(.leading, 14)
            AgentAddRuleRow(store: store, builtIn: builtIn)
        }
        askedTools
        SettingsSection("Always allowed (built in)", footer: "What every agent runs without asking. Commands only when every part of the "
                        + "line is one of these, also with output redirected (> or >>) into the agent\u{2019}s own scratchpad; anything the check is unsure about is asked.") {
            if let builtIn {
                DisclosureGroup("\(builtIn.tools.count + 1) tools, \(builtIn.commands.count) commands") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tools: " + (builtIn.tools + ["WorkTime\u{2019}s MCP tools except the ones that ask: " + builtIn.alwaysAsk.map(AgentLogic.displayName)
                            .joined(separator: ", ")]).joined(separator: ", "))
                        ForEach(builtIn.lines, id: \.self) { Text($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                SettingsRow("Not found", detail: "Build the agent sidecar (npm run build in agent) to see the list") {}
            }
        }
    }

    private var codexDetail: String {
        switch codexSetup.status {
        case .missing: return "Codex CLI not found. Install Codex, then choose it here."
        case .signedIn(let text): return codexSetup.account ?? text
        case .signedOut(let text): return text + " Copy `codex login`, run it in Terminal and sign in with ChatGPT."
        }
    }

    var builtIn = AgentRules.builtIn

    @ViewBuilder private var askedTools: some View {
        if let builtIn, !builtIn.alwaysAsk.isEmpty {
            SettingsSection("Tools that ask", footer: "These ask every time until you switch Don\u{2019}t ask on for one. Routines and automations still never skip the question, "
                            + "and Plan mode still asks.") {
                ForEach(Array(builtIn.alwaysAsk.enumerated()), id: \.element) { index, tool in
                    let risky = AgentRules.isRisky(tool, builtIn: builtIn)
                    if index > 0 { Divider().padding(.leading, 14) }
                    SettingsRow(AgentLogic.displayName(tool), detail: risky ? AgentRules.riskNote(tool) : nil) {
                        if risky { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Toggle("Don\u{2019}t ask", isOn: dontAsk(tool, risky: risky)).fixedSize()
                    }
                }
            }
            .confirmationDialog("Stop asking before this tool runs?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible, presenting: confirming) { tool in
                Button("Don\u{2019}t Ask for \(AgentLogic.displayName(tool))", role: .destructive) { store.add([AgentRules.dontAsk(tool)]) }
                Button("Cancel", role: .cancel) {}
            } message: { Text(AgentRules.riskNote($0)) }
        }
    }

    private func dontAsk(_ tool: String, risky: Bool) -> Binding<Bool> {
        Binding(get: { store.rules.contains(AgentRules.dontAsk(tool)) }, set: { on in
            if !on { store.remove(AgentRules.dontAsk(tool)) } else if risky { confirming = tool } else { store.add([AgentRules.dontAsk(tool)]) }
        })
    }
}

/// Adds a rule by hand: a command prefix typed in, edits in a folder, or one of WorkTime's tools.
/// The websites Claude in Chrome may act on without asking, with Remove for each and a field to add one.
private struct ChromeSitesRows: View {
    @ObservedObject private var store = AgentChromeSiteStore.shared
    @State private var text = ""

    private var typed: String? { AgentChromeSites.host(text) }

    var body: some View {
        ForEach(store.hosts, id: \.self) { host in
            Divider().padding(.leading, 14)
            SettingsRow("Allowed site \(host)", detail: host.hasPrefix("*.") ? "Its subdomains, not the site itself" : nil) {
                Button("Remove") { store.remove(host) }
            }
        }
        Divider().padding(.leading, 14)
        HStack {
            TextField("Allow a site", text: $text, prompt: Text("example.com or *.example.com"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add).disabled(typed == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func add() {
        guard let typed else { return }
        store.add(typed)
        text = ""
    }
}

private struct AgentAddRuleRow: View {
    @ObservedObject var store: AgentRuleStore
    let builtIn: AgentBuiltIn?
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add rule", text: $text, prompt: Text("Command, like gh pr view *"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCommand)
                Button("Add", action: addCommand).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("More") {
                    Button("Edits in a Folder\u{2026}", action: addFolder)
                    Menu("Claude in Chrome Action") {
                        ForEach(AgentRules.chromeChoices, id: \.self) { tool in
                            Button(AgentRules.toolLabel(tool)) { store.add([AgentRule(kind: .tool, value: tool)]) }
                        }
                    }
                    if let builtIn {
                        Menu("WorkTime Tool") {
                            ForEach(AgentRules.toolChoices(MCPServer.toolNames, builtIn: builtIn), id: \.self) { tool in
                                Button(AgentLogic.displayName(tool)) { store.add([AgentRule(kind: .tool, value: tool)]) }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if case .success(let rule) = AgentRules.bashRule(text), let warning = AgentRules.warning([rule]) {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .onChange(of: text) { problem = nil }
    }

    private func addCommand() {
        switch AgentRules.bashRule(text) {
        case .success(let rule):
            store.add([rule])
            text = ""
        case .failure(let error): problem = error.message
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Allow Edits"
        if panel.runModal() == .OK, let url = panel.url { store.add([AgentRule(kind: .edits, value: url.path)]) }
    }
}

private struct AgentCode: View {
    /// How many lines a long command or result shows before Show all.
    static let previewLines = 6

    let text: String
    var font: Font.TextStyle = .caption
    var maxHeight: CGFloat = 220
    var collapsedLines: Int?
    @State private var showAll = false

    private var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: false) }
    private var hidden: Int { collapsedLines.map { max(lines.count - $0, 0) } ?? 0 }

    /// The height of `count` lines of monospaced text in `font`, with the box's padding.
    static func lines(_ count: Int, font: NSFont.TextStyle) -> CGFloat {
        let face = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: font).pointSize, weight: .regular)
        return ceil(face.ascender - face.descender + face.leading) * CGFloat(count) + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(hidden > 0 && !showAll ? lines.prefix(collapsedLines ?? lines.count).joined(separator: "\n") + " \u{2026}" : text)
                    .font(.system(font, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            if hidden > 0 {
                Button(showAll ? "Show less" : "Show all \(lines.count) lines") { showAll.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A saved image, loaded off the main thread, at a fixed size.
private struct AgentThumbnail: View {
    let path: String
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.08)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: path) { image = await Task.detached { NSImage(contentsOfFile: path) }.value }
    }
}

/// The messages sent while the agent works that have not reached it yet, each of which can still be taken back.
struct AgentPendingList: View {
    @ObservedObject var model: AgentModel
    @Environment(\.transcriptTypography) private var typography

    var body: some View {
        ForEach(model.pending) { send in
            HStack(spacing: 8) {
                Text("Queued").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(send.text.isEmpty ? "\(send.images.count) image\(send.images.count == 1 ? "" : "s")" : send.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.cancelPending(send) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Take this message back")
            }
            .font(typography?.small ?? .callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
        }
    }
}

/// The pictures waiting to be sent with the next message, each removable, and why one was refused.
struct AgentImageChips: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        if !model.images.isEmpty || model.imageNote != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !model.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(model.images) { image in
                            AgentThumbnail(path: image.path, side: 56)
                                .overlay(alignment: .topTrailing) {
                                    Button { model.removeImage(image) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(2)
                                    .help("Remove")
                                }
                        }
                        Spacer()
                    }
                }
                if let note = model.imageNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14)
        }
    }
}
