import Foundation

/// The search of the agents sidebar: every word of the query has to be found, in any case, in what a row shows or last said.
enum AgentSearch {
    static let openRequested = Notification.Name("AgentSearchOpenRequested")

    static func terms(_ query: String) -> [String] { query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    static func isActive(_ query: String) -> Bool { !terms(query).isEmpty }

    static func matches(_ query: String, in fields: [String?]) -> Bool {
        let haystack = fields.compactMap { $0 }.joined(separator: "\n").lowercased()
        return terms(query).allSatisfy(haystack.contains)
    }

    /// A pull request as people type it: its address, `repo#12`, and the number alone.
    fileprivate static func pullRequestFields(_ url: String?, titles: [String: String]) -> [String?] {
        guard let url else { return [] }
        let number = GitHubLink.pullRequest(at: url).map { String($0.number) }
        return [url, AgentSessions.shortReference(url), number, titles[url]]
    }

    static func fields(of state: AgentState, titles: [String: String] = [:]) -> [String?] {
        let urls = [state.prURL, state.sessionPR] + (state.pullRequests ?? []).map(Optional.some)
        return [state.title, state.jiraKey, AgentListFilter.sidebarRole(state), state.lastPrompt, state.lastResult]
            + urls.flatMap { pullRequestFields($0, titles: titles) }
    }

    static func fields(of routine: Routine) -> [String?] { [routine.name, routine.prompt, routine.lastRun?.summary, routine.assistant] }

    static func filter(_ states: [AgentState], query: String, titles: [String: String] = [:], links: AgentLinkIndex = .empty) -> [AgentState] {
        guard isActive(query) else { return states }
        let words = terms(query)
        let linked = words.map { links.agentKeys(named: $0) }
        return states.filter { state in
            let fields = fields(of: state, titles: titles) + [links.text(ofAgent: state.key, titles: titles)]
            let haystack = fields.compactMap { $0 }.joined(separator: "\n").lowercased()
            return words.indices.allSatisfy { haystack.contains(words[$0]) || linked[$0].contains(state.key) }
        }
    }

    /// The agents the link table ties to what the query says: a ticket, pull request or branch it names reaches the agents linked to it or
    /// one hop further, and its words are looked for in the titles and names of what each agent is linked to.
    static func linkedKeys(query: String, agents: [AgentState], links: AgentLinkIndex, titles: [String: String] = [:]) -> Set<String> {
        guard isActive(query), !links.isEmpty else { return [] }
        let keys = Set(agents.map(\.key))
        let named = links.agentKeys(named: query).intersection(keys)
        let said = agents.filter { matches(query, in: [links.text(ofAgent: $0.key, titles: titles)]) }.map(\.key)
        return named.union(said)
    }

    static func filter(_ routines: [Routine], query: String) -> [Routine] {
        guard isActive(query) else { return routines }
        return routines.filter { matches(query, in: fields(of: $0)) }
    }
}

enum AddToAgent {
    /// The keys of `agents`, in their order, that the link table ties to one of the pull requests.
    static func linkedAgents(of prs: [LinkedPR], agents: [String], index: AgentLinkIndex) -> [String] {
        let linked = index.agentKeys(linkedTo: prs)
        return agents.filter(linked.contains)
    }
}

/// The link table as the search reads it, built once per table: what an entity is called (ref, aliases, the forms people type for a pull
/// request or branch) and what it says about itself.
struct AgentLinkIndex: Sendable {
    static let empty = AgentLinkIndex(table: LinkTable())
    private static let reach = 2

    private let table: LinkTable
    private let references: [String: [LinkEntity]]
    private let texts: [LinkEntity: String]

    init(table: LinkTable) {
        var references: [String: [LinkEntity]] = [:]
        var texts: [LinkEntity: String] = [:]
        for record in table.entities.values where record.kind != .agent {
            let names = [record.ref] + record.aliases
            let addresses = record.kind == .githubPR ? names.compactMap(LinkTargets.pullRequestURL) : []
            let typed = addresses.flatMap { [$0, AgentSessions.shortReference($0)] } + (record.kind == .branch ? names.compactMap(Self.branchName) : [])
            for name in names + typed { references[name.lowercased(), default: []].append(record.entity) }
            let fields = names + [record.title] + addresses.flatMap { AgentSearch.pullRequestFields($0, titles: [:]) }
            texts[record.entity] = fields.compactMap { $0 }.joined(separator: "\n").lowercased()
        }
        (self.table, self.references, self.texts) = (table, references, texts)
    }

    var isEmpty: Bool { table.entities.isEmpty }

    func ticketKeys(for state: AgentState) -> [String] {
        var tickets = table.neighbors(of: .agent(state.key)).filter { $0.kind == .jira }
        let linked = table.neighbors(of: .agent(state.key)).filter { $0.kind == .githubPR || $0.kind == .branch }
        let urls = [state.prURL, state.sessionPR].compactMap { $0 } + (state.pullRequests ?? [])
        for entity in Set(linked + urls.compactMap(LinkTargets.pullRequest)) {
            tickets += table.neighbors(of: entity).filter { $0.kind == .jira }
        }
        return Set(tickets.map(\.id) + [state.jiraKey].compactMap { $0?.uppercased() }).sorted()
    }

    private static func branchName(_ ref: String) -> String? { ref.firstIndex(of: ":").map { String(ref[ref.index(after: $0)...]) } }

    /// The agents within two hops of the ticket, pull request or branch a single word names.
    func agentKeys(named query: String) -> Set<String> {
        let words = AgentSearch.terms(query)
        guard words.count == 1, let word = words.first else { return [] }
        let found = (references[word] ?? []) + (references[LinkTargets.parse(word)?.id.lowercased() ?? ""] ?? [])
        return Set(found.flatMap { table.related(to: $0, depth: Self.reach) }.filter { $0.entity.kind == .agent }.map(\.entity.id))
    }

    /// The agents within two hops of any of the pull requests: linked to one directly, or through its ticket or branch.
    func agentKeys(linkedTo prs: [LinkedPR]) -> Set<String> {
        Set(prs.flatMap { table.related(to: .pullRequest($0.target), depth: Self.reach) }.filter { $0.entity.kind == .agent }.map(\.entity.id))
    }

    /// What the agent's linked entities are called, plus the titles known for their pull requests.
    func text(ofAgent key: String, titles: [String: String]) -> String {
        table.neighbors(of: .agent(key)).map { entity in
            [texts[entity], LinkTargets.pullRequestURL(entity.id).flatMap { titles[$0] }].compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// The sidebar's search box: whether it is showing, what it holds, and a count that moves focus into it when Find is used again.
struct AgentSearchField: Equatable {
    var isOpen = false
    var query = ""
    var focusTick = 0

    mutating func open() {
        isOpen = true
        focusTick += 1
    }

    mutating func close() {
        isOpen = false
        query = ""
    }
}
