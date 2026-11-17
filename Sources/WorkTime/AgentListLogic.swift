import Foundation

/// What the "Agents" section of the sidebar shows: every agent of a workspace, or one kind of them.
enum AgentListFilter: String, CaseIterable, Identifiable, Sendable {
    case all, pullRequests, tickets, sets

    static let storageKey = "agentListFilter"
    static let collapsedKey = "agentListCollapsed"

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

    /// The comma separated ids with `id` taken out when it is in, put in when it is not.
    static func toggling(_ id: String, in ids: String) -> String {
        var set = Set(ids.split(separator: ",").map(String.init))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        return set.sorted().joined(separator: ",")
    }

    static func contains(_ id: String, in ids: String) -> Bool { ids.split(separator: ",").contains { $0 == id } }
}
