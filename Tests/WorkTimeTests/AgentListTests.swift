import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func topicKey() -> String { TopicAgents.prefix + UUID().uuidString }

private func pullRequest(_ url: String = "https://github.com/acme-com/api/pull/1") -> AgentState {
    AgentState(key: url, title: "api#1", prURL: url, status: .idle)
}

private func ticket() -> AgentState {
    var state = AgentState(key: topicKey(), title: "PROJ-1", status: .idle)
    state.jiraKey = "PROJ-1"
    return state
}

private func supportCase() -> AgentState { AgentState(key: topicKey(), title: "A support case", status: .idle) }

private func set(_ urls: [String]) -> AgentState {
    var state = AgentState(key: topicKey(), title: "Review: api", status: .idle)
    state.pullRequests = urls
    return state
}

let agentListTests: [(name: String, run: () throws -> Void)] = [
    ("agent list: a pull request, a ticket, a support case and a set each get their kind", {
        check(AgentListFilter.kind(of: pullRequest()) == .pullRequests, "pull request")
        check(AgentListFilter.kind(of: ticket()) == .tickets, "ticket")
        check(AgentListFilter.kind(of: supportCase()) == .tickets, "support case counts as a ticket")
        check(AgentListFilter.kind(of: set(["https://github.com/acme-com/api/pull/1", "https://github.com/acme-com/ui/pull/2"])) == .sets, "set")
        var empty = supportCase()
        empty.pullRequests = []
        check(AgentListFilter.kind(of: empty) == .tickets, "a topic with no pull requests is not a set")
    }),
    ("agent list: the counts add up and the chips appear only when there is more than one kind", {
        let agents = [pullRequest(), pullRequest("https://github.com/acme-com/api/pull/2"), ticket(), set(["https://github.com/acme-com/api/pull/3"])]
        let counts = AgentListFilter.counts(agents)
        check(counts[.all] == 4 && counts[.pullRequests] == 2 && counts[.tickets] == 1 && counts[.sets] == 1, "counts")
        check(AgentListFilter.chips(counts: counts) == [.all, .pullRequests, .tickets, .sets], "all four")
        check(AgentListFilter.chips(counts: AgentListFilter.counts([pullRequest(), pullRequest("https://github.com/acme-com/api/pull/2")])).isEmpty, "one kind")
        check(AgentListFilter.chips(counts: AgentListFilter.counts([])).isEmpty, "none")
        check(AgentListFilter.chips(counts: AgentListFilter.counts([pullRequest(), ticket()])) == [.all, .pullRequests, .tickets], "only the kinds present")
    }),
    ("agent list: a filter shows only its kind and All shows every agent in order", {
        let first = pullRequest(), second = ticket(), third = pullRequest("https://github.com/acme-com/api/pull/2")
        let agents = [first, second, third]
        check(AgentListFilter.shown(agents, filter: .all).map(\.key) == agents.map(\.key), "all keeps the order")
        check(AgentListFilter.shown(agents, filter: .pullRequests).map(\.key) == [first.key, third.key], "pull requests")
        check(AgentListFilter.shown(agents, filter: .tickets).map(\.key) == [second.key], "tickets")
        check(AgentListFilter.shown(agents, filter: .sets).isEmpty, "no sets")
    }),
    ("agent list: a filter chosen for another workspace falls back to All here", {
        let counts = AgentListFilter.counts([pullRequest(), ticket()])
        check(AgentListFilter.effective(.sets, counts: counts) == .all, "no sets in this workspace")
        check(AgentListFilter.effective(.tickets, counts: counts) == .tickets, "tickets exist")
        check(AgentListFilter.effective(.all, counts: counts) == .all, "all stays")
        check(AgentListFilter.effective(.sets, counts: AgentListFilter.counts([])) == .all, "empty workspace")
    }),
    ("agent list: collapsing a workspace's agents toggles its id in the saved list", {
        check(AgentListFilter.toggling("work", in: "") == "work", "collapse")
        check(AgentListFilter.toggling("reviews", in: "work") == "reviews,work", "second one, sorted")
        check(AgentListFilter.toggling("work", in: "reviews,work") == "reviews", "expand")
        check(AgentListFilter.contains("work", in: "reviews,work") && !AgentListFilter.contains("rev", in: "reviews,work"), "whole ids only")
    }),
    ("agent list: the section is titled Agents and the filter titles are the ones offered", {
        check(AgentListFilter.allCases.map(\.title) == ["All", "Pull requests", "Tickets", "Sets"], "titles")
        check(AgentListFilter(rawValue: "nonsense") == nil, "an unknown stored value is ignored")
    }),
]
