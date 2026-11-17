import SwiftUI

/// A workspace's pull request, ticket and set agents under their own collapsible "Agents" header, with a button to make one
/// and chips to show only one kind.
struct AgentsSection<Row: View>: View {
    let workspace: Workspace
    let agents: [AgentState]
    let onNew: () -> Void
    @ViewBuilder let row: (AgentState) -> Row
    @AppStorage(AgentListFilter.collapsedKey) private var collapsed = ""
    @AppStorage(AgentListFilter.storageKey) private var chosen = AgentListFilter.all.rawValue

    var body: some View {
        let isCollapsed = AgentListFilter.contains(workspace.id, in: collapsed)
        let counts = AgentListFilter.counts(agents)
        let filter = AgentListFilter.effective(AgentListFilter(rawValue: chosen) ?? .all, counts: counts)
        header(isCollapsed: isCollapsed)
        if !isCollapsed {
            let chips = AgentListFilter.chips(counts: counts)
            if !chips.isEmpty { chipRow(chips, counts: counts, selected: filter) }
            ForEach(AgentListFilter.shown(agents, filter: filter), id: \.key) { row($0) }
        }
    }

    private func header(isCollapsed: Bool) -> some View {
        HStack(spacing: 4) {
            Button { collapsed = AgentListFilter.toggling(workspace.id, in: collapsed) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text("Agents").font(.caption2.weight(.semibold))
                    Text("\(agents.count)").font(.caption2).foregroundStyle(.tertiary)
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
                    Button { chosen = chip.rawValue } label: {
                        HStack(spacing: 3) {
                            Text(chip.title)
                            Text("\(counts[chip] ?? 0)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(chip == selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
