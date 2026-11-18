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
    ("agent list: finished tickets and merged or closed pull requests are hidden unless asked for or searched", {
        let done = ticket(), open = pullRequest(), merged = pullRequest("https://github.com/acme-com/api/pull/2"), closed = pullRequest("https://github.com/acme-com/api/pull/3")
        let projects: Set<String> = ["PROJ"]
        let infos = [
            SessionRef.jira("PROJ-1").cacheKey: SessionRefInfo(status: "Done", category: "done"),
            SessionRef.pullRequest(repo: "acme-com/api", number: 1).cacheKey: SessionRefInfo(state: "open"),
            SessionRef.pullRequest(repo: "acme-com/api", number: 2).cacheKey: SessionRefInfo(state: "merged"),
            SessionRef.pullRequest(repo: "acme-com/api", number: 3).cacheKey: SessionRefInfo(state: "closed"),
        ]
        func keys(showDone: Bool = false, searching: Bool = false, _ states: [AgentState]) -> [String] {
            AgentListFilter.unfinished(states, showDone: showDone, searching: searching, projects: projects, titles: [:], infos: infos).map(\.key)
        }
        let all = [done, open, merged, closed]
        check(keys(all) == [open.key], "only the open pull request stays")
        check(keys(showDone: true, all) == all.map(\.key), "Show done reveals them")
        check(keys(searching: true, all) == all.map(\.key), "a search still finds them")
        check(AgentListFilter.counts(AgentListFilter.unfinished(all, showDone: false, searching: false, projects: projects, titles: [:], infos: infos))[.all] == 1, "counts follow")
        check(AgentListFilter.unfinished([supportCase()], showDone: false, searching: false, projects: projects, titles: [:], infos: [:]).count == 1, "no info keeps it")
    }),
    ("agent list: a finished agent that works, waits or has an unseen result stays visible", {
        let infos = [SessionRef.pullRequest(repo: "acme-com/api", number: 1).cacheKey: SessionRefInfo(state: "merged")]
        func stays(_ change: (inout AgentState) -> Void) -> Bool {
            var state = pullRequest()
            change(&state)
            return !AgentListFilter.isFinished(state, projects: [], titles: [:], infos: infos)
        }
        check(!stays { _ in }, "idle and merged is finished")
        check(stays { $0.status = .working }, "working")
        check(stays { $0.status = .waiting }, "waiting for permission")
        check(stays { $0.status = .error }, "error")
        check(stays { $0.lastResult = "Done"; $0.seen = false }, "unseen result")
    }),
    ("agent list: rows not active since the start of today go under Older unless they need the user", {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let startOfToday = calendar.startOfDay(for: now)
        func agent(_ url: String, _ updated: Date?, _ change: (inout AgentState) -> Void = { _ in }) -> TicketRow {
            var state = pullRequest(url)
            state.updatedAt = updated
            change(&state)
            return .agent(state)
        }
        let fresh = agent("https://github.com/acme-com/api/pull/1", now.addingTimeInterval(-3600))
        let midnight = agent("https://github.com/acme-com/api/pull/2", startOfToday)
        let lastNight = agent("https://github.com/acme-com/api/pull/3", startOfToday.addingTimeInterval(-1))
        let old = agent("https://github.com/acme-com/api/pull/4", now.addingTimeInterval(-6 * 86_400))
        let working = agent("https://github.com/acme-com/api/pull/5", now.addingTimeInterval(-6 * 86_400)) { $0.status = .working }
        let waiting = agent("https://github.com/acme-com/api/pull/6", now.addingTimeInterval(-6 * 86_400)) { $0.status = .waiting }
        let unseen = agent("https://github.com/acme-com/api/pull/7", now.addingTimeInterval(-6 * 86_400)) { $0.lastResult = "Done"; $0.seen = false }
        let unknown = agent("https://github.com/acme-com/api/pull/8", nil)
        let split = AgentListFilter.splitOlder([fresh, midnight, lastNight, old, working, waiting, unseen, unknown], now: now, calendar: calendar)
        check(split.today.map(\.id) == [fresh, midnight, working, waiting, unseen, unknown].map(\.id), "today's and the ones that need the user")
        check(split.older.map(\.id) == [lastNight, old].map(\.id), "before today is older")

        var member = pullRequest("https://github.com/acme-com/api/pull/9")
        member.updatedAt = now.addingTimeInterval(-3 * 86_400)
        var recent = member
        recent.updatedAt = now.addingTimeInterval(-60)
        let mixed = TicketRow.group(TicketGroup(subject: .ticket("PROJ-1"), members: [member, recent]))
        check(AgentListFilter.splitOlder([mixed], now: now, calendar: calendar).older.isEmpty, "a group follows its latest session")
    }),
]
