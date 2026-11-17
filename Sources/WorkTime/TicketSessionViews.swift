import AppKit
import SwiftUI

/// The questions about reusing a ticket's session that wait for the user, in Main's chat: the same buttons as the notification and the notch bar.
struct TicketAskCards: View {
    let workspace: String?
    @ObservedObject private var store = TicketAskStore.shared

    var body: some View {
        ForEach(store.asks(in: workspace)) { ask in card(ask) }
    }

    private func card(_ ask: TicketAsk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ask.title, systemImage: "questionmark.bubble").font(.callout.weight(.medium))
            Text(ask.body(now: Date())).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Waiting to send: " + TicketSessions.clip(ask.text)).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            HStack(spacing: 6) {
                Button("Reuse this one") { store.respond(ask.id, .reuse) }.buttonStyle(.borderedProminent)
                Button("Start a new one") { store.respond(ask.id, .startNew) }.buttonStyle(.bordered)
                Button("Always reuse for \(ask.assistantName)") { store.respond(ask.id, .alwaysReuse) }.buttonStyle(.bordered)
                    .help("Reuse the session without asking from now on for this assistant; Settings \u{203A} Agent can change it back")
                Button("Open it") { store.open(ask.id) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.6)))
    }
}

/// A ticket's sessions in the agents list: one row for the ticket with its title and status, and under it the sessions by role.
struct TicketGroupView<Member: View>: View {
    let group: TicketGroup
    let member: (AgentState) -> Member
    @AppStorage("agentTicketGroupsCollapsed") private var collapsed = ""
    @ObservedObject private var directory = SessionRefDirectory.shared
    @ObservedObject private var asks = TicketAskStore.shared
    @ObservedObject private var jira = JiraModel.shared

    private var collapsedKeys: Set<String> { Set(collapsed.split(separator: ",").map(String.init)) }
    private var isCollapsed: Bool { collapsedKeys.contains(group.ticket) }
    private var info: SessionRefInfo? { directory.entries[SessionRef.jira(group.ticket).cacheKey]?.info }
    private var asking: Bool { asks.isAsking(ticket: group.ticket) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !isCollapsed { ForEach(group.members, id: \.key) { member($0) } }
        }
        .task(id: group.ticket) { await directory.ensure([.jira(group.ticket)], skip: []) }
    }

    private var header: some View {
        let need = asking ? AgentOverview.Need.waiting : group.need
        return HStack(spacing: 6) {
            Button { toggle() } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary).frame(width: 12)
            }
            .buttonStyle(.plain)
            Circle().fill(AgentList.color(need)).frame(width: 8, height: 8).help(asking ? "Waiting for your choice: reuse a session or start a new one" : need.label)
            BrandMark.jira.resizable().scaledToFit().frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.ticket).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                    if let status = info?.status { StatusChip(text: status, kind: info?.statusKind) }
                    Spacer(minLength: 4)
                    Text("\(group.members.count)").font(.caption2).foregroundStyle(.tertiary)
                    if let updated = group.latest {
                        Text(GitHubLogic.updatedText(updated, now: Date())).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let title = info?.title, !title.isEmpty { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if asking { Text("Reuse a session or start a new one?").font(.caption2).foregroundStyle(.orange) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .contextMenu {
            if let site = jira.site, let url = JiraLogic.browseURL(site: site, key: group.ticket) {
                Button("Open \(group.ticket) in Jira") { NSWorkspace.shared.open(url) }
            }
        }
        .help(isCollapsed ? "Show the sessions for \(group.ticket)" : "Hide the sessions for \(group.ticket)")
    }

    private func toggle() {
        var keys = collapsedKeys
        if isCollapsed { keys.remove(group.ticket) } else { keys.insert(group.ticket) }
        collapsed = keys.sorted().joined(separator: ",")
    }
}

/// One session in a ticket's group: its role, what it is doing, indented under the ticket.
struct TicketMemberRow: View {
    let state: AgentState
    let selected: Bool

    var body: some View {
        let need = AgentOverview.need(state)
        HStack(spacing: 7) {
            Circle().fill(AgentList.color(need)).frame(width: 7, height: 7).help(need.label)
            if let entry = state.roleKey.flatMap({ AssistantStore.shared.entry($0) }) {
                AssistantIcon(name: entry.role.icon)
            } else if state.prURL != nil {
                Image(systemName: "arrow.triangle.pull").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "text.bubble").font(.caption).foregroundStyle(.secondary)
            }
            Text(TicketGrouping.label(state)).font(.callout).lineLimit(1)
            Spacer(minLength: 4)
            if state.slotWait == true {
                Label("Waiting for a free slot", systemImage: "hourglass").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if state.error != nil, state.status == .idle {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red).help(state.error ?? "")
            } else if need != .idle {
                Text(need.label).font(.caption2).foregroundStyle(AgentList.color(need)).lineLimit(1)
            } else if let updated = state.updatedAt {
                Text(GitHubLogic.updatedText(updated, now: Date())).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }
}

/// Settings › Agent: what to do when a ticket's session exists, and how many assistant sessions work at once.
struct AssistantSessionSettings: View {
    @AppStorage(TicketSessions.policyKey) private var policy = TicketSessions.Policy.ask.rawValue
    @AppStorage(TicketSessions.limitKey) private var limit = TicketSessions.defaultLimit
    @State private var always = TicketSessions.alwaysReuse()

    var body: some View {
        SettingsSection("Assistant sessions", footer: "Main sends work on a ticket to an assistant with its own session for that ticket. "
            + "An assistant can ask for fewer at once with concurrency in its file.") {
            SettingsRow("When a session for the ticket exists", detail: "Main\u{2019}s send waits for your answer, up to the time set for a tool\u{2019}s question.") {
                Picker("When a session for the ticket exists", selection: $policy) {
                    ForEach(TicketSessions.Policy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if !always.isEmpty {
                SettingsRow("Always reuse for", detail: always.sorted().map { AssistantStore.shared.entry($0)?.role.name ?? $0 }.joined(separator: ", ")) {
                    Button("Reset") {
                        UserDefaults.standard.removeObject(forKey: TicketSessions.alwaysReuseKey)
                        always = []
                    }
                }
            }
            SettingsRow("Sessions working at once", detail: limit == 0 ? "No limit" : "\(limit) at most; the others wait for a free slot") {
                Stepper("Sessions working at once", value: $limit, in: 0...12).labelsHidden()
            }
        }
    }
}
