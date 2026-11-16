import Foundation

enum JiraTab: String, CaseIterable, Identifiable, Codable {
    case assigned, reported, watching

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// What makes a ticket belong to the tab.
    var condition: String {
        switch self {
        case .assigned: return "assignee = currentUser() AND resolution = Unresolved"
        case .reported: return "reporter = currentUser()"
        case .watching: return "watcher = currentUser()"
        }
    }

    var jql: String { condition + " ORDER BY updated DESC" }
}

enum JiraStage: String, CaseIterable {
    case todo, inProgress, inReview, done

    var title: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .done: return "Done"
        }
    }
}

/// The chips above the list; each narrows the tab's tickets.
enum JiraStatusTab: String, CaseIterable, Identifiable, Codable {
    case all, myTurn, inReview, blocked, done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .myTurn: return "My turn"
        case .inReview: return "In review"
        case .blocked: return "Blocked"
        case .done: return "Done recently"
        }
    }
}

/// What the Filters menu and the search field narrow the list to. Each value is one name or several separated by commas,
/// like the `jira_search` arguments of the same names.
struct JiraFilter: Equatable, Codable {
    var status = JiraStatusTab.all
    var query = ""
    var project: String?
    var type: String?
    var statusName: String?
    var priority: String?
    var assignee: String?
    var sort = JiraSort.updated
    var group = JiraGrouping.none

    /// The search text is not part of what is remembered or saved.
    enum CodingKeys: String, CodingKey { case status, project, type, statusName, priority, assignee, sort, group }

    init(status: JiraStatusTab = .all, query: String = "", project: String? = nil, type: String? = nil, statusName: String? = nil,
         priority: String? = nil, assignee: String? = nil, sort: JiraSort = .updated, group: JiraGrouping = .none) {
        self.status = status
        self.query = query
        self.project = project
        self.type = type
        self.statusName = statusName
        self.priority = priority
        self.assignee = assignee
        self.sort = sort
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(status: (try? values.decode(JiraStatusTab.self, forKey: .status)) ?? .all,
                  project: try? values.decode(String.self, forKey: .project), type: try? values.decode(String.self, forKey: .type),
                  statusName: try? values.decode(String.self, forKey: .statusName), priority: try? values.decode(String.self, forKey: .priority),
                  assignee: try? values.decode(String.self, forKey: .assignee),
                  sort: (try? values.decode(JiraSort.self, forKey: .sort)) ?? .updated,
                  group: (try? values.decode(JiraGrouping.self, forKey: .group)) ?? .none)
    }

    var withoutText: JiraFilter {
        var filter = self
        filter.query = ""
        return filter
    }

    var refinements: Int { [project, type, statusName, priority, assignee].filter { $0 != nil }.count }

    var withoutRefinements: JiraFilter { JiraFilter(status: status, query: query, sort: sort, group: group) }
}

enum JiraTickets {
    static let pageSize = 50
    static let recentDays = 7.0

    // MARK: Status

    static func stage(_ ticket: JiraTicket) -> JiraStage {
        let name = ticket.status.lowercased()
        switch ticket.category {
        case .done: return .done
        case .todo: return .todo
        case .inProgress: return name.contains("review") || name.contains("verif") ? .inReview : .inProgress
        case nil:
            if ["done", "closed", "resolved", "released"].contains(where: name.contains) { return .done }
            if ["to do", "todo", "backlog", "open", "new"].contains(name) { return .todo }
            return name.contains("review") || name.contains("verif") ? .inReview : .inProgress
        }
    }

    static func isBlocked(_ ticket: JiraTicket) -> Bool {
        ticket.status.lowercased().contains("block") || ticket.labels.contains { $0.lowercased().contains("block") }
    }

    /// My turn is a ticket assigned to me that is not done, not blocked and not waiting for a review.
    static func includes(_ tab: JiraStatusTab, _ ticket: JiraTicket, mine: Set<String>, now: Date) -> Bool {
        switch tab {
        case .all: return true
        case .myTurn: return mine.contains(ticket.key) && ![.done, .inReview].contains(stage(ticket)) && !isBlocked(ticket)
        case .inReview: return stage(ticket) == .inReview
        case .blocked: return stage(ticket) != .done && isBlocked(ticket)
        case .done:
            return stage(ticket) == .done && ticket.updated.map { now.timeIntervalSince($0) <= recentDays * 86_400 } ?? false
        }
    }

    // MARK: Filtering

    static func project(of key: String) -> String { key.split(separator: "-").first.map(String.init) ?? key }

    static func filter(_ tickets: [JiraTicket], _ filter: JiraFilter, mine: Set<String>, now: Date) -> [JiraTicket] {
        let words = filter.query.lowercased().split(separator: " ").map(String.init)
        return tickets.filter { ticket in
            guard includes(filter.status, ticket, mine: mine, now: now),
                  matches(filter.project, project(of: ticket.key)), matches(filter.type, ticket.type),
                  matches(filter.statusName, ticket.status), matches(filter.priority, ticket.priority),
                  matches(filter.assignee, ticket.assignee, empty: ["unassigned", "none"]) else { return false }
            let haystack = "\(ticket.key) \(ticket.summary) \(ticket.labels.joined(separator: " "))".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Whether the value is one of the wanted names, ignoring case; no wanted names let everything through. A ticket without
    /// the value matches only the names in `empty`.
    static func matches(_ wanted: String?, _ value: String?, empty: [String] = []) -> Bool {
        let names = JQLFilter.list(wanted).map { $0.lowercased() }
        guard !names.isEmpty else { return true }
        guard let value else { return names.contains { empty.contains($0) } }
        return names.contains(value.lowercased())
    }

    static func counts(_ tickets: [JiraTicket], _ filter: JiraFilter, mine: Set<String>, now: Date) -> [JiraStatusTab: Int] {
        Dictionary(uniqueKeysWithValues: JiraStatusTab.allCases.map { tab in
            var tabbed = filter
            tabbed.status = tab
            return (tab, Self.filter(tickets, tabbed, mine: mine, now: now).count)
        })
    }

    struct Options: Equatable {
        var projects: [String] = []
        var types: [String] = []
        var statuses: [String] = []
        var priorities: [String] = []
        var assignees: [String] = []
    }

    /// The values the Filters menu offers: what the tickets shown carry, sorted.
    static func options(_ tickets: [JiraTicket]) -> Options {
        func sorted(_ values: [String?]) -> [String] {
            Array(Set(values.compactMap { $0 })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return Options(projects: sorted(tickets.map { project(of: $0.key) }), types: sorted(tickets.map(\.type)),
                       statuses: sorted(tickets.map(\.status)), priorities: sorted(tickets.map(\.priority)),
                       assignees: sorted(tickets.map(\.assignee)))
    }

    /// The tab's JQL with the filters ANDed on, through the same composing `jira_search` uses.
    static func jql(_ tab: JiraTab, _ filter: JiraFilter) -> String { JiraQuery.jql(tab, filter) }

    /// The Jira issue navigator for a JQL query.
    static func navigatorURL(site: String, jql: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = site
        components.path = "/issues/"
        components.queryItems = [URLQueryItem(name: "jql", value: jql)]
        return components.url
    }

    // MARK: Pull requests

    /// The cached pull requests by the ticket key their title or head branch carries, open ones first.
    static func pullRequests(_ prs: [GitHubPR], head: (GitHubPR) -> String?) -> [String: [GitHubPR]] {
        var found: [String: [GitHubPR]] = [:]
        for pr in prs {
            for key in Set([ActivityLogic.ticket(in: pr.title), ActivityLogic.ticket(in: head(pr))].compactMap { $0 }) {
                found[key, default: []].append(pr)
            }
        }
        return found.mapValues { $0.sorted { ($0.state == .open ? 0 : 1, $1.updated) < ($1.state == .open ? 0 : 1, $0.updated) } }
    }

    /// The ticket agents among the agents the app knows, by the key of their ticket.
    static func agents(_ states: [AgentState]) -> [String: AgentState] {
        Dictionary(states.compactMap { state in state.isTopic ? state.jiraKey.map { ($0, state) } : nil }) { first, _ in first }
    }

    // MARK: Fetching and caching

    struct Fetch {
        var lists: [JiraTab: [JiraTicket]] = [:]
        var error: JiraError?
    }

    /// Every tab's tickets. A tab that fails is left out and the first error is reported, so the others still show.
    static func fetchAll(client: JiraClient) async -> Fetch {
        var fetch = Fetch()
        for tab in JiraTab.allCases {
            do { fetch.lists[tab] = try await client.search(jql: tab.jql, max: pageSize, fields: JiraLogic.listFields).tickets } catch {
                fetch.error = fetch.error ?? JiraError.from(error)
            }
        }
        return fetch
    }

    struct Cache: Codable, Equatable {
        var fetched: Date
        var lists: [JiraTab: [JiraTicket]]
    }

    static func encode(_ cache: Cache) -> Data { AgentInbox.encode(cache) }

    static func decode(_ data: Data?) -> Cache? { data.flatMap { AgentInbox.decode(Cache.self, from: $0) } }

    /// The keys of the tickets assigned to me, which the other tabs cannot tell.
    static func mine(_ lists: [JiraTab: [JiraTicket]]) -> Set<String> { Set((lists[.assigned] ?? []).map(\.key)) }

    static func header(count: Int, tab: JiraTab, capped: Bool) -> String {
        "\(count)\(capped ? "+" : "") \(tab.title.lowercased())"
    }
}
