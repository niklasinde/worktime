import SwiftUI

/// A workspace's pull request, ticket and set agents under their own collapsible "Agents" header, with a button to make one
/// and chips to show only one kind.
struct AgentsSection<Row: View, TicketRow: View>: View {
    let workspace: Workspace
    let agents: [AgentState]
    /// Pull requests' titles by address, for the sessions that name a ticket only there.
    var titles: [String: String] = [:]
    /// Only the agents in this space, with every agent about the same ticket or pull request as one of them.
    var space: String?
    var query = ""
    let onNew: () -> Void
    @ViewBuilder let row: (AgentState) -> Row
    /// A ticket's sessions gathered under one row.
    @ViewBuilder let group: (TicketGroup) -> TicketRow
    @AppStorage(AgentListFilter.collapsedKey) private var collapsed = ""
    @State private var folded: Set<String> = []
    @AppStorage(AgentListFilter.storageKey) private var chosen = AgentListFilter.all.rawValue
    @AppStorage(AgentListFilter.showDoneKey) private var showDone = false
    @AppStorage(AgentListFilter.olderOpenKey) private var olderOpen = false
    @ObservedObject private var directory = SessionRefDirectory.shared
    @ObservedObject private var linkStore = LinkStore.shared
    @State private var showLinks = false

    var body: some View {
        let searching = AgentSearch.isActive(query)
        let isCollapsed = AgentListFilter.contains(workspace.id, in: collapsed) && !searching
        let projects = Set(workspace.jiraProjects.map { $0.uppercased() })
        let everything = Self.scoped(agents, workspace: workspace, space: space, titles: titles, query: query, links: linkStore.searchIndex)
        let infos = directory.entries.compactMapValues(\.info)
        let scoped = AgentListFilter.unfinished(everything, showDone: showDone, searching: searching, projects: projects, titles: titles, infos: infos)
        let hidden = everything.filter { $0.archived != true }.count - scoped.filter { $0.archived != true }.count
        let counts = AgentListFilter.counts(scoped)
        let filter = searching ? .all : AgentListFilter.effective(AgentListFilter(rawValue: chosen) ?? .all, counts: counts)
        let live = scoped.filter { $0.archived != true }
        if !searching || !live.isEmpty {
            header(isCollapsed: isCollapsed, count: live.count)
        }
        if !isCollapsed {
            let chips = searching ? [] : AgentListFilter.chips(counts: counts)
            if !searching, !chips.isEmpty || hidden > 0 || showDone { chipRow(chips, counts: counts, selected: filter, hidden: hidden) }
            let groups = Dictionary(grouping: AgentListFilter.shown(scoped, filter: filter), by: AgentListFilter.sidebarRole)
            ForEach(groups.keys.sorted(), id: \.self) { role in
                roleGroup(role, members: groups[role] ?? [], projects: projects, searching: searching)
            }
        }
    }

    @ViewBuilder private func roleGroup(_ role: String, members: [AgentState], projects: Set<String>, searching: Bool) -> some View {
        let id = workspace.id + "/" + role
        let closed = folded.contains(id) && !searching
        sectionToggle(role, count: members.filter { $0.archived != true }.count, collapsed: closed) { toggle(id) }
            .padding(.leading, 32)
        if !closed {
            let rows = AgentListFilter.ticketRows(members, projects: projects, titles: titles, links: linkStore.searchIndex)
            ForEach(AgentListFilter.entries(rows, olderOpen: olderOpen || searching, now: Date())) { entry in
                switch entry {
                case .row(.group(let ticket)):
                    let ticketID = id + "/" + ticket.id
                    let ticketClosed = folded.contains(ticketID) && !searching
                    if let key = ticket.ticket {
                        sectionToggle(key, count: ticket.members.count, collapsed: ticketClosed) { toggle(ticketID) }
                            .padding(.leading, 42)
                            .contextMenu {
                                if ticket.members.contains(where: { TicketGrouping.subject(of: $0, projects: projects, titles: titles) == ticket.subject }) {
                                    Button("Open Ticket Timeline") { AgentHub.shared.show(ticket.id) }
                                }
                            }
                        if !ticketClosed {
                            ForEach(ticket.members, id: \.key) { state in row(state).padding(.leading, 18) }
                        }
                    } else { group(ticket) }
                case .row(let value): rowView(value)
                case .olderHeader(let count, let isOpen): olderHeader(count: count, isOpen: isOpen)
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if !folded.insert(key).inserted { folded.remove(key) }
    }

    @ViewBuilder private func rowView(_ entry: WorkTime.TicketRow) -> some View {
        switch entry {
        case .agent(let state): row(state)
        case .group(let ticket): group(ticket)
        }
    }

    private func olderHeader(count: Int, isOpen: Bool) -> some View {
        Button { olderOpen.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("Older").font(.caption2.weight(.medium))
                Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 26)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide the agents last active before today" : "Show the agents last active before today")
    }

    static func scoped(_ agents: [AgentState], workspace: Workspace, space: String?, titles: [String: String], query: String, links: AgentLinkIndex = .empty) -> [AgentState] {
        let projects = Set(workspace.jiraProjects.map { $0.uppercased() })
        return AgentSearch.filter(Spaces.related(agents, space: space, projects: projects, titles: titles), query: query, titles: titles, links: links)
    }

    private func header(isCollapsed: Bool, count: Int) -> some View {
        HStack(spacing: 4) {
            sectionToggle("Agents", count: count, collapsed: isCollapsed) {
                collapsed = AgentListFilter.toggling(workspace.id, in: collapsed)
            }
            .help(isCollapsed ? "Show the agents of \(workspace.name)" : "Hide the agents of \(workspace.name)")
            Spacer()
            Button { showLinks = true } label: { Image(systemName: "link").font(.caption) }
                .buttonStyle(.plain)
                .help("Links: the tickets, pull requests and branches each agent has to do with")
                .sheet(isPresented: $showLinks) { LinksView(agents: agents) }
            Button(action: onNew) { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.plain)
                .help("New Agent: an agent for a support case or other topic, linked to a Jira ticket or Slack thread")
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.top, 2)
    }

    private func sectionToggle(_ title: String, count: Int, collapsed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(title).font(.caption2.weight(.semibold))
                Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chipRow(_ chips: [AgentListFilter], counts: [AgentListFilter: Int], selected: AgentListFilter, hidden: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(chips) { chip in
                    FilterChip(title: chip.title, count: counts[chip] ?? 0, selected: chip == selected) { chosen = chip.rawValue }
                }
                if hidden > 0 || showDone {
                    FilterChip(title: "Show done", count: showDone ? nil : hidden, icon: "checkmark.circle", selected: showDone) { showDone.toggle() }
                        .help(showDone ? "Hide agents whose ticket is Done or whose pull request is merged or closed" : "Show the agents whose ticket is Done or whose pull request is merged or closed")
                }
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
