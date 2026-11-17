import Foundation

enum JiraSort: String, CaseIterable, Identifiable, Codable {
    case updated, priority

    var id: String { rawValue }
    var title: String { self == .updated ? "Last updated" : "Priority" }
    var orderBy: String { self == .updated ? "ORDER BY updated DESC" : "ORDER BY priority DESC, updated DESC" }
}

enum JiraGrouping: String, CaseIterable, Identifiable, Codable {
    case none, status

    var id: String { rawValue }
    var title: String { self == .none ? "No grouping" : "By status" }
}

struct JiraGroup: Equatable, Identifiable {
    let title: String
    let tickets: [JiraTicket]

    var id: String { title }
}

/// A comma-separated filter value as the Filters menu toggles it.
enum JiraChoices {
    static func contains(_ list: String?, _ value: String) -> Bool {
        JQLFilter.list(list).contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// `list` with `value` added, or taken out when it is there; nil when nothing is left.
    static func toggled(_ list: String?, _ value: String) -> String? {
        var values = JQLFilter.list(list)
        if let index = values.firstIndex(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { values.remove(at: index) } else { values.append(value) }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

/// What the assignee filter holds: `me`, `unassigned`, `anyone`, or `@` and a person's account id, several separated by commas.
enum JiraAssignee {
    static let me = "me"
    static let unassigned = "unassigned"
    static let anyone = "anyone"
    static let idPrefix = "@"

    static func token(for person: JiraPerson) -> String { idPrefix + person.id }

    /// Anyone stands alone; every other choice toggles and drops Anyone.
    static func toggled(_ list: String?, _ token: String) -> String? {
        if token == anyone { return JiraChoices.contains(list, anyone) ? nil : anyone }
        let others = JQLFilter.list(list).filter { $0.caseInsensitiveCompare(anyone) != .orderedSame }.joined(separator: ", ")
        return JiraChoices.toggled(others, token)
    }

    static func label(_ token: String, people: [String: String]) -> String {
        switch token.lowercased() {
        case me: return "Me"
        case unassigned: return "Unassigned"
        case anyone: return "Anyone"
        default: return token.hasPrefix(idPrefix) ? people[String(token.dropFirst())] ?? "Someone" : token
        }
    }

    static func summary(_ list: String?, people: [String: String]) -> String {
        JQLFilter.list(list).map { label($0, people: people) }.joined(separator: ", ")
    }

    /// The values `JQLFilter` quotes: people by account id, Anyone left out.
    static func queryValue(_ list: String?) -> String? {
        let values = JQLFilter.list(list).filter { $0.caseInsensitiveCompare(anyone) != .orderedSame }
            .map { $0.hasPrefix(idPrefix) ? String($0.dropFirst()) : $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

/// The JQL behind the page's filters, and when the list is fetched with it instead of taken from the tab's cache.
enum JiraQuery {
    static let rawPrefix = "jql:"

    /// The query typed after `jql:` in the search field.
    static func raw(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(rawPrefix) else { return nil }
        let query = trimmed.dropFirst(rawPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? nil : query
    }

    static func isRaw(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(rawPrefix) }

    /// The tab's own cached list answers a filter that changes nothing in the query.
    static func needsServer(_ filter: JiraFilter) -> Bool { filter.refinements > 0 || filter.sort != .updated }

    /// Whether the assignee filter takes the place of the Assigned tab's own "assigned to me".
    static func replacesAssignee(_ tab: JiraTab, _ filter: JiraFilter) -> Bool {
        tab == .assigned && !JQLFilter.list(filter.assignee).isEmpty
    }

    static func jql(_ tab: JiraTab, _ filter: JiraFilter) -> String {
        let condition = replacesAssignee(tab, filter) ? "resolution = Unresolved" : tab.condition
        let arguments: [String: Any] = ["project": filter.project, "type": filter.type, "status": filter.statusName, "priority": filter.priority,
                                        "assignee": JiraAssignee.queryValue(filter.assignee)].compactMapValues { $0 }
        let clauses = (try? JQLFilter.clauses(arguments)) ?? []
        return JQLFilter.compose(jql: condition + " " + filter.sort.orderBy, clauses: clauses)
    }

    static func title(count: Int, capped: Bool, tab: JiraTab, filter: JiraFilter) -> String {
        if isRaw(filter.query) { return "\(count)\(capped ? "+" : "") results" }
        if replacesAssignee(tab, filter) { return "\(count)\(capped ? "+" : "") tickets" }
        return JiraTickets.header(count: count, tab: tab, capped: capped)
    }

    /// The projects to offer: the workspaces' own first, then any others the tickets or the filter carry.
    static func projectChoices(configured: [String], seen: [String], selected: String?) -> [String] {
        var choices: [String] = []
        for project in (configured + JQLFilter.list(selected) + seen).map({ $0.uppercased() }) where !choices.contains(project) { choices.append(project) }
        let extra = choices.dropFirst(configured.count).sorted()
        return Array(choices.prefix(configured.count)) + extra
    }

    /// A name for the filters as they stand, such as "ISD, ACME · Waiting for customer · Unassigned".
    static func summary(_ tab: JiraTab, _ filter: JiraFilter, people: [String: String]) -> String {
        let parts = [filter.project.map { JQLFilter.list($0).joined(separator: ", ") }, filter.statusName.map { JQLFilter.list($0).joined(separator: ", ") },
                     filter.type, filter.priority, filter.assignee.map { JiraAssignee.summary($0, people: people) },
                     filter.status == .all ? nil : filter.status.title].compactMap { $0 }
        return parts.isEmpty ? tab.title : parts.joined(separator: " \u{00B7} ")
    }
}

extension JiraTickets.Options {
    /// The options with the values the filter has chosen, so a choice stays on the menu after it empties the list.
    func including(_ filter: JiraFilter) -> JiraTickets.Options {
        func merged(_ values: [String], _ chosen: String?) -> [String] {
            var all = values
            for value in JQLFilter.list(chosen) where !all.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { all.append(value) }
            return all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        return JiraTickets.Options(projects: merged(projects, filter.project), types: merged(types, filter.type),
                                   statuses: merged(statuses, filter.statusName), priorities: merged(priorities, filter.priority),
                                   assignees: assignees)
    }
}

extension JiraTickets {
    private static let stageOrder: [JiraStage] = [.inProgress, .inReview, .todo, .done]

    /// The tickets under one heading per status, in the order the work moves; one untitled group without grouping.
    static func groups(_ tickets: [JiraTicket], by grouping: JiraGrouping) -> [JiraGroup] {
        guard !tickets.isEmpty else { return [] }
        guard grouping == .status else { return [JiraGroup(title: "", tickets: tickets)] }
        let byStatus = Dictionary(grouping: tickets, by: \.status)
        return byStatus.keys.sorted { first, second in
            let ranks = [first, second].map { name in stageOrder.firstIndex(of: stage(byStatus[name]![0])) ?? stageOrder.count }
            return ranks[0] != ranks[1] ? ranks[0] < ranks[1] : first.localizedCaseInsensitiveCompare(second) == .orderedAscending
        }.map { JiraGroup(title: $0, tickets: byStatus[$0]!) }
    }

    /// The people the tickets are assigned to, by name.
    static func people(_ tickets: [JiraTicket]) -> [JiraPerson] {
        var seen = Set<String>()
        return tickets.compactMap { ticket in
            guard let id = ticket.assigneeID, let name = ticket.assignee, seen.insert(id).inserted else { return nil }
            return JiraPerson(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A named combination of tab and filters, kept to come back to.
struct JiraSavedView: Codable, Equatable, Identifiable {
    var name: String
    var tab: JiraTab
    var filter: JiraFilter

    var id: String { name.lowercased() }
}

enum JiraSavedViews {
    static let key = "jiraSavedViews"
    static let pageStateKey = "jiraPageState"
    static let nameLimit = 60

    /// The views with this one added, or replacing the one of the same name.
    static func saving(_ view: JiraSavedView, in views: [JiraSavedView]) -> [JiraSavedView] {
        var view = view
        view.name = String(view.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
        guard !view.name.isEmpty else { return views }
        var filter = view.filter
        filter.query = ""
        view.filter = filter
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return views + [view] }
        var updated = views
        updated[index] = view
        return updated
    }

    static func removing(_ name: String, from views: [JiraSavedView]) -> [JiraSavedView] {
        views.filter { $0.id != name.lowercased() }
    }

    /// The saved view the page shows exactly, to mark it on the menu.
    static func current(_ tab: JiraTab, _ filter: JiraFilter, in views: [JiraSavedView]) -> JiraSavedView? {
        var shown = filter
        shown.query = ""
        return views.first { $0.tab == tab && $0.filter == shown }
    }

    static func encode(_ views: [JiraSavedView]) -> Data { AgentInbox.encode(views) }

    static func decode(_ data: Data?) -> [JiraSavedView] {
        data.flatMap { AgentInbox.decode([JiraSavedView].self, from: $0) } ?? []
    }
}

/// The tab and filters the page was left on.
struct JiraPageState: Codable, Equatable {
    var tab: JiraTab
    var filter: JiraFilter

    static func encode(_ state: JiraPageState) -> Data { AgentInbox.encode(state) }

    static func decode(_ data: Data?) -> JiraPageState? { data.flatMap { AgentInbox.decode(JiraPageState.self, from: $0) } }
}
