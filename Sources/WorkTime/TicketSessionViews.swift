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

/// A ticket's or pull request's sessions in the agents list: one row for the subject with its title and status, its pull requests as chips,
/// the sessions under it by role, and the closed ones under "Earlier". The clock opens its timeline.
struct TicketGroupView<Member: View>: View {
    let group: TicketGroup
    var titles: [String: String] = [:]
    let select: (String) -> Void
    let openTimeline: () -> Void
    var spaceMenu: ((TicketGroup) -> AnyView)?
    @ViewBuilder let member: (AgentState) -> Member
    @AppStorage("agentTicketGroupsCollapsed") private var collapsed = ""
    @AppStorage("agentTicketGroupsEarlier") private var earlierOpen = ""
    @ObservedObject private var directory = SessionRefDirectory.shared
    @ObservedObject private var asks = TicketAskStore.shared
    @ObservedObject private var jira = JiraModel.shared

    private var key: String { group.id }
    private var isCollapsed: Bool { Set(collapsed.split(separator: ",").map(String.init)).contains(key) }
    private var showsEarlier: Bool { Set(earlierOpen.split(separator: ",").map(String.init)).contains(key) }
    private var ref: SessionRef? {
        switch group.subject {
        case .ticket(let key): .jira(key)
        case .pullRequest(let url): GitHubLink.pullRequest(at: url).map(SessionRef.init)
        }
    }
    private var info: SessionRefInfo? { ref.flatMap { directory.entries[$0.cacheKey]?.info } }
    private var title: String? {
        if let title = info?.title, !title.isEmpty { return title }
        return group.subject.pullRequest.flatMap { titles[$0] }
    }
    private var asking: Bool { asks.isAsking(subject: group.subject) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if !isCollapsed {
                if !group.chips.isEmpty { chips }
                ForEach(group.rows, id: \.key) { member($0) }
                if !group.earlier.isEmpty { earlier }
            }
        }
        .task(id: group.id) { if let ref { await directory.ensure([ref], skip: []) } }
    }

    private var header: some View {
        let need = asking ? AgentOverview.Need.waiting : group.need
        return HStack(spacing: 6) {
            Button { toggle(&collapsed) } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary).frame(width: 12)
            }
            .buttonStyle(.plain)
            Circle().fill(AgentList.color(need)).frame(width: 8, height: 8).help(asking ? "Waiting for your choice: reuse a session or start a new one" : need.label)
            if group.ticket != nil {
                BrandMark.jira.resizable().scaledToFit().frame(width: 12, height: 12)
            } else {
                Image(systemName: "arrow.triangle.pull").font(.caption).foregroundStyle(.secondary).frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(group.subject.label).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                    if group.ticket != nil, let status = info?.status { StatusChip(text: status, kind: info?.statusKind) }
                    Spacer(minLength: 4)
                    Text("\(group.live.count)").font(.caption2).foregroundStyle(.tertiary)
                    if let updated = group.latest {
                        Text(GitHubLogic.updatedText(updated, now: Date())).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let title, !title.isEmpty { Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if asking { Text("Reuse a session or start a new one?").font(.caption2).foregroundStyle(.orange) }
            }
            Button(action: openTimeline) { Image(systemName: "clock.arrow.circlepath").font(.caption) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Timeline of \(group.subject.label): what triggered it, what was asked, the outcomes and the reviews, across its sessions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggle(&collapsed) }
        .contextMenu {
            Button("Open Timeline", action: openTimeline)
            if let ticket = group.ticket, let site = jira.site, let url = JiraLogic.browseURL(site: site, key: ticket) {
                Button("Open \(ticket) in Jira") { NSWorkspace.shared.open(url) }
            }
            if let url = group.subject.pullRequest.flatMap(URL.init(string:)) { Button("Open in Browser") { NSWorkspace.shared.open(url) } }
            if let spaceMenu { spaceMenu(group) }
        }
        .help(isCollapsed ? "Show the sessions for \(group.subject.label)" : "Hide the sessions for \(group.subject.label)")
    }

    /// The ticket's pull requests: a chip each, which opens the agent or session about it, or lists them when there are several.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(group.chips) { chip in
                    if chip.sessions.count == 1 {
                        Button { select(chip.sessions[0].key) } label: { chipLabel(chip) }.buttonStyle(.plain)
                    } else {
                        Menu {
                            ForEach(chip.sessions, id: \.key) { state in Button(TicketGrouping.label(state)) { select(state.key) } }
                        } label: { chipLabel(chip) }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                    }
                }
            }
            .padding(.leading, 30)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chipLabel(_ chip: PullRequestChip) -> some View {
        let need = chip.sessions.map(AgentOverview.need).min() ?? .idle
        return HStack(spacing: 4) {
            Circle().fill(AgentList.color(need)).frame(width: 6, height: 6)
            Text(chip.label).font(.caption2.monospaced())
            if chip.sessions.count > 1 { Text("\(chip.sessions.count)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Pull request \(chip.label)\(chip.sessions.count > 1 ? ": \(chip.sessions.count) agents and sessions" : "")")
    }

    /// The closed sessions: kept, so what was said and done stays one click away.
    @ViewBuilder private var earlier: some View {
        Button { toggle(&earlierOpen) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(showsEarlier ? 90 : 0))
                Text("Earlier").font(.caption2.weight(.medium))
                Text("\(group.earlier.count)").font(.caption2).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if showsEarlier { ForEach(group.earlier, id: \.key) { member($0).opacity(0.7) } }
    }

    private func toggle(_ store: inout String) {
        var keys = Set(store.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        store = keys.sorted().joined(separator: ",")
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
