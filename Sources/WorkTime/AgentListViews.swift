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
    @AppStorage(AgentListFilter.storageKey) private var chosen = AgentListFilter.all.rawValue

    var body: some View {
        let searching = AgentSearch.isActive(query)
        let isCollapsed = AgentListFilter.contains(workspace.id, in: collapsed) && !searching
        let projects = Set(workspace.jiraProjects.map { $0.uppercased() })
        let scoped = Self.scoped(agents, workspace: workspace, space: space, titles: titles, query: query)
        let counts = AgentListFilter.counts(scoped)
        let filter = searching ? .all : AgentListFilter.effective(AgentListFilter(rawValue: chosen) ?? .all, counts: counts)
        let live = scoped.filter { $0.archived != true }
        if !searching || !live.isEmpty {
            header(isCollapsed: isCollapsed, count: live.count)
        }
        if !isCollapsed {
            let chips = searching ? [] : AgentListFilter.chips(counts: counts)
            if !chips.isEmpty { chipRow(chips, counts: counts, selected: filter) }
            ForEach(TicketGrouping.rows(AgentListFilter.shown(scoped, filter: filter), projects: projects, titles: titles)) { entry in
                switch entry {
                case .agent(let state): row(state)
                case .group(let ticket): group(ticket)
                }
            }
        }
    }

    static func scoped(_ agents: [AgentState], workspace: Workspace, space: String?, titles: [String: String], query: String) -> [AgentState] {
        let projects = Set(workspace.jiraProjects.map { $0.uppercased() })
        return AgentSearch.filter(Spaces.related(agents, space: space, projects: projects, titles: titles), query: query, titles: titles)
    }

    private func header(isCollapsed: Bool, count: Int) -> some View {
        HStack(spacing: 4) {
            Button { collapsed = AgentListFilter.toggling(workspace.id, in: collapsed) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text("Agents").font(.caption2.weight(.semibold))
                    Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the agents of \(workspace.name)" : "Hide the agents of \(workspace.name)")
            Spacer()
            Button(action: onNew) { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.plain)
                .help("New Agent: an agent for a support case or other topic, linked to a Jira ticket or Slack thread")
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.top, 2)
    }

    private func chipRow(_ chips: [AgentListFilter], counts: [AgentListFilter: Int], selected: AgentListFilter) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(chips) { chip in
                    FilterChip(title: chip.title, count: counts[chip] ?? 0, selected: chip == selected) { chosen = chip.rawValue }
                }
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
