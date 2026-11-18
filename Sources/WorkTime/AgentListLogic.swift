import Foundation

/// What the "Agents" section of the sidebar shows: every agent of a workspace, or one kind of them.
enum AgentListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, pullRequests, tickets, sets

    static let storageKey = "agentListFilter"
    static let collapsedKey = "agentListCollapsed"
    static let showDoneKey = "agentListShowDone"
    static let olderOpenKey = "agentListOlderOpen"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pullRequests: "Pull requests"
        case .tickets: "Tickets"
        case .sets: "Sets"
        }
    }

    /// A set holds several pull requests; the other topic agents (a ticket, a Slack thread, a support case) count as tickets;
    /// the rest are one pull request's agent.
    static func kind(of state: AgentState) -> AgentListFilter {
        guard state.isTopic else { return .pullRequests }
        return state.pullRequests?.isEmpty == false ? .sets : .tickets
    }

    func includes(_ state: AgentState) -> Bool { self == .all || Self.kind(of: state) == self }

    static func counts(_ states: [AgentState]) -> [AgentListFilter: Int] {
        let states = states.filter { $0.archived != true }
        var counts: [AgentListFilter: Int] = [.all: states.count]
        for state in states { counts[kind(of: state), default: 0] += 1 }
        return counts
    }

    /// The chips to offer: All and each kind that has agents, and none when everything is of one kind.
    static func chips(counts: [AgentListFilter: Int]) -> [AgentListFilter] {
        let kinds = allCases.filter { $0 != .all && (counts[$0] ?? 0) > 0 }
        return kinds.count > 1 ? [.all] + kinds : []
    }

    /// The chosen kind, or All when this workspace has none of it, so the list is never empty for a filter chosen elsewhere.
    static func effective(_ filter: AgentListFilter, counts: [AgentListFilter: Int]) -> AgentListFilter {
        filter == .all || (counts[filter] ?? 0) > 0 ? filter : .all
    }

    static func shown(_ states: [AgentState], filter: AgentListFilter) -> [AgentState] { states.filter(filter.includes) }

    /// The ticket or pull request an agent is about, for the lookup of its status.
    static func ref(of state: AgentState, projects: Set<String>, titles: [String: String]) -> SessionRef? {
        switch TicketGrouping.subject(of: state, projects: projects, titles: titles) {
        case .ticket(let key)?: .jira(key)
        case .pullRequest(let url)?: GitHubLink.pullRequest(at: url).map(SessionRef.init)
        case nil: nil
        }
    }

    /// Its ticket is Done or its pull request merged or closed, and nothing in it needs the user.
    static func isFinished(_ state: AgentState, projects: Set<String>, titles: [String: String], infos: [String: SessionRefInfo]) -> Bool {
        guard AgentOverview.need(state) == .idle,
              let info = ref(of: state, projects: projects, titles: titles).flatMap({ infos[$0.cacheKey] }) else { return false }
        return info.statusKind == .done || info.state == "merged" || info.state == "closed"
    }

    /// The agents without the finished ones, unless they are asked for or a search is looking for them.
    static func unfinished(_ states: [AgentState], showDone: Bool, searching: Bool, projects: Set<String>, titles: [String: String],
                           infos: [String: SessionRefInfo]) -> [AgentState] {
        guard !showDone, !searching else { return states }
        return states.filter { !isFinished($0, projects: projects, titles: titles, infos: infos) }
    }

    /// The rows split into today's and the older ones. Anything not active since the start of today is older, so yesterday evening is
    /// already tucked away; a row that works, waits, errors, has an unseen result, or has no known activity stays with today's.
    static func splitOlder(_ rows: [TicketRow], now: Date, calendar: Calendar = .current) -> (today: [TicketRow], older: [TicketRow]) {
        let startOfToday = calendar.startOfDay(for: now)
        func isOlder(_ row: TicketRow) -> Bool {
            let (activity, need): (Date?, AgentOverview.Need) = switch row {
            case .agent(let state): (state.updatedAt, AgentOverview.need(state))
            case .group(let group): (group.latest, group.need)
            }
            guard let activity else { return false }
            return need == .idle && activity < startOfToday
        }
        return (rows.filter { !isOlder($0) }, rows.filter(isOlder))
    }

    /// Today's rows, then the Older header and, when open, the older rows, as one flat list so the lazy stack sees a single ForEach.
    static func entries(_ rows: [TicketRow], olderOpen: Bool, now: Date, calendar: Calendar = .current) -> [AgentListEntry] {
        let split = splitOlder(rows, now: now, calendar: calendar)
        var entries = split.today.map(AgentListEntry.row)
        if !split.older.isEmpty {
            entries.append(.olderHeader(count: split.older.count, isOpen: olderOpen))
            if olderOpen { entries += split.older.map(AgentListEntry.row) }
        }
        return entries
    }

    /// The comma separated ids with `id` taken out when it is in, put in when it is not.
    static func toggling(_ id: String, in ids: String) -> String {
        var set = Set(ids.split(separator: ",").map(String.init))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: ",")
    }

    static func contains(_ id: String, in ids: String) -> Bool { ids.split(separator: ",").contains { $0 == id } }
}

enum AgentListEntry: Identifiable, Equatable {
    case row(TicketRow)
    case olderHeader(count: Int, isOpen: Bool)

    var id: String {
        switch self {
        case .row(let row): row.id
        case .olderHeader: "agent-list-older"
        }
    }
}
