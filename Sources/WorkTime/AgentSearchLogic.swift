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
    private static func pullRequestFields(_ url: String?, titles: [String: String]) -> [String?] {
        guard let url else { return [] }
        let number = GitHubLink.pullRequest(at: url).map { String($0.number) }
        return [url, AgentSessions.shortReference(url), number, titles[url]]
    }

    static func fields(of state: AgentState, titles: [String: String] = [:]) -> [String?] {
        let urls = [state.prURL, state.sessionPR] + (state.pullRequests ?? []).map(Optional.some)
        return [state.title, state.jiraKey, state.role, state.lastPrompt, state.lastResult]
            + urls.flatMap { pullRequestFields($0, titles: titles) }
    }

    static func fields(of routine: Routine) -> [String?] { [routine.name, routine.prompt, routine.lastRun?.summary, routine.assistant] }

    static func filter(_ states: [AgentState], query: String, titles: [String: String] = [:]) -> [AgentState] {
        guard isActive(query) else { return states }
        return states.filter { matches(query, in: fields(of: $0, titles: titles)) }
    }

    static func filter(_ routines: [Routine], query: String) -> [Routine] {
        guard isActive(query) else { return routines }
        return routines.filter { matches(query, in: fields(of: $0)) }
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
