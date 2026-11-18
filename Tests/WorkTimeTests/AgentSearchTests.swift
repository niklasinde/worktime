import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let prURL = "https://github.com/acme-com/api/pull/1234"

private func state(_ title: String, pr: String? = nil, jira: String? = nil, prompt: String? = nil, result: String? = nil) -> AgentState {
    var state = AgentState(key: UUID().uuidString, title: title, prURL: pr, status: .idle)
    state.jiraKey = jira
    state.lastPrompt = prompt
    state.lastResult = result
    return state
}

private func routine(_ name: String, prompt: String = "", summary: String? = nil) -> Routine {
    var routine = Routine(id: UUID().uuidString, name: name, prompt: prompt, workspace: "work", schedule: .every(minutes: 60), created: Date())
    routine.lastRun = RoutineRun(started: Date(), status: .done, summary: summary)
    return routine
}


private let linkStart = Date(timeIntervalSince1970: 1_792_300_000)

private func linkedAgent(_ key: String) -> AgentState { AgentState(key: key, title: "session \(key)", status: .idle) }

private func linkedTable(_ pairs: [(LinkEntity, LinkEntity)], titles: [LinkEntity: String] = [:]) -> LinkTable {
    var table = LinkTable()
    for (first, second) in pairs { table.upsert(LinkPair(first, second), source: .manual, now: linkStart) }
    let records = table.allEntities.map { record -> LinkEntityRecord in
        var record = record
        record.title = titles[record.entity]
        return record
    }
    return LinkTable(entities: records, links: table.allLinks)
}

private func linkedKeys(_ query: String, _ agents: [AgentState], _ table: LinkTable, titles: [String: String] = [:]) -> Set<String> {
    AgentSearch.linkedKeys(query: query, agents: agents, links: AgentLinkIndex(table: table), titles: titles)
}

private let linkedPR = LinkTargets.pullRequest("acme-com/api#12")!
private let linkedBranch = LinkEntity.branch("api:NI/ACME-5-export")

let agentSearchTests: [(name: String, run: () throws -> Void)] = [
    ("agent search: a blank query is not a search and keeps everything", {
        let states = [state("one"), state("two")]
        check(!AgentSearch.isActive("   "), "blank")
        check(AgentSearch.filter(states, query: " ").count == 2, "all kept")
    }),
    ("agent search: every word has to match, in any case, in any of the fields", {
        let agent = state("Fix login", jira: "ACME-12", result: "Deployed to staging")
        check(AgentSearch.filter([agent], query: "acme-12 STAGING").count == 1, "key and result")
        check(AgentSearch.filter([agent], query: "login prod").isEmpty, "one word missing")
    }),
    ("agent search: a pull request is found by number, repo#number and its title", {
        let agent = state("api#1234", pr: prURL)
        check(AgentSearch.filter([agent], query: "1234").count == 1, "number")
        check(AgentSearch.filter([agent], query: "api#1234").count == 1, "short reference")
        check(AgentSearch.filter([agent], query: "rate limit").isEmpty, "title unknown")
        check(AgentSearch.filter([agent], query: "rate limit", titles: [prURL: "Add rate limiting"]).count == 1, "title")
    }),
    ("agent search: the last prompt and result are searched", {
        let agent = state("Main", prompt: "summarise the invoices", result: "three overdue")
        check(AgentSearch.filter([agent], query: "invoices").count == 1, "prompt")
        check(AgentSearch.filter([agent], query: "overdue").count == 1, "result")
    }),
    ("agent search: routines and automations are found by name, prompt and last summary", {
        let routines = [routine("Morning sweep", prompt: "Check my pull requests", summary: "two need review"), routine("Nightly")]
        check(AgentSearch.filter(routines, query: "sweep").count == 1, "name")
        check(AgentSearch.filter(routines, query: "pull requests").count == 1, "prompt")
        check(AgentSearch.filter(routines, query: "need review").count == 1, "summary")
        check(AgentSearch.filter(routines, query: "zzz").isEmpty, "none")
    }),
    ("agent search: opening shows the box and asks for focus again each time, closing clears the query", {
        var field = AgentSearchField()
        field.open()
        field.query = "api"
        field.open()
        check(field.isOpen && field.focusTick == 2 && field.query == "api", "open twice keeps the query")
        field.close()
        check(!field.isOpen && field.query.isEmpty, "closed and cleared")
    }),
    ("agent search by links: a key finds the agents on it, on a pull request of it and on a branch of it", {
        let agents = [linkedAgent("a"), linkedAgent("b"), linkedAgent("c"), linkedAgent("d")]
        let table = linkedTable([(.agent("a"), .jira("ACME-5")), (.agent("b"), linkedPR), (linkedPR, .jira("ACME-5")),
                                 (.agent("c"), linkedBranch), (linkedBranch, .jira("ACME-5")), (.agent("d"), .jira("ACME-9"))])
        check(linkedKeys("acme-5", agents, table) == ["a", "b", "c"], "ticket, pull request and branch")
        check(linkedKeys("ACME-9", agents, table) == ["d"], "other ticket")
    }),
    ("agent search by links: a pull request or branch finds the agents on its ticket", {
        let agents = [linkedAgent("a"), linkedAgent("b"), linkedAgent("c")]
        let table = linkedTable([(.agent("a"), .jira("ACME-5")), (linkedPR, .jira("ACME-5")), (.agent("b"), .jira("ACME-5")), (linkedBranch, .jira("ACME-5")),
                                 (.agent("c"), .jira("ACME-9"))])
        for query in ["acme-com/api#12", "api#12", "https://github.com/acme-com/api/pull/12"] {
            check(linkedKeys(query, agents, table) == ["a", "b"], query)
        }
        check(linkedKeys("NI/ACME-5-export", agents, table) == ["a", "b"], "branch name")
        check(linkedKeys("api:NI/ACME-5-export", agents, table) == ["a", "b"], "branch ref")
    }),
    ("agent search by links: an old Jira key still finds the agent", {
        var table = linkedTable([(.agent("a"), .jira("OLD-1"))])
        table.rename(.jira("OLD-1"), to: "NEW-2")
        check(linkedKeys("old-1", [linkedAgent("a")], table) == ["a"], "alias")
        check(linkedKeys("new-2", [linkedAgent("a")], table) == ["a"], "new key")
    }),
    ("agent search by links: a removed link is ignored", {
        var table = linkedTable([(.agent("a"), .jira("ACME-5")), (.agent("b"), linkedPR), (linkedPR, .jira("ACME-5"))])
        table.remove(LinkPair(linkedPR, .jira("ACME-5")), now: linkStart)
        check(linkedKeys("ACME-5", [linkedAgent("a"), linkedAgent("b")], table) == ["a"], "between ticket and pull request")
        table.remove(LinkPair(.agent("a"), .jira("ACME-5")), now: linkStart)
        check(linkedKeys("ACME-5", [linkedAgent("a"), linkedAgent("b")], table).isEmpty, "to the agent")
    }),
    ("agent search by links: words match the titles of the linked ticket and pull request", {
        let agents = [linkedAgent("a"), linkedAgent("b")]
        let table = linkedTable([(.agent("a"), .jira("ACME-5")), (.agent("b"), linkedPR)], titles: [.jira("ACME-5"): "Export invoices as CSV"])
        check(linkedKeys("export csv", agents, table) == ["a"], "ticket title")
        check(linkedKeys("rate limit", agents, table).isEmpty, "pull request title unknown")
        check(linkedKeys("rate limit", agents, table, titles: ["https://github.com/acme-com/api/pull/12": "Add rate limiting"]) == ["b"], "cached pull request title")
        check(linkedKeys("export rate", agents, table).isEmpty, "every word in one agent's links")
    }),
    ("agent search by links: no match adds nothing and the text match stays", {
        let agents = [linkedAgent("a")]
        let table = linkedTable([(.agent("a"), .jira("ACME-5"))])
        check(linkedKeys("zzz", agents, table).isEmpty, "nothing")
        check(linkedKeys("   ", agents, table).isEmpty, "blank")
        check(linkedKeys("ACME-5", agents, .init()).isEmpty, "empty table")
        let titled = state("Fix export")
        let other = state("unrelated")
        check(AgentSearch.filter([titled, other], query: "export", links: AgentLinkIndex(table: table)).count == 1, "text only")
        let linked = linkedAgent("a")
        check(AgentSearch.filter([linked, other], query: "acme-5", links: AgentLinkIndex(table: table)).map(\.key) == ["a"], "links only")
    }),
    ("agent search by links: 300 agents and 1000 links stay fast", {
        let agents = (0..<300).map { linkedAgent("agent-\($0)") }
        var pairs: [(LinkEntity, LinkEntity)] = []
        for (index, agent) in agents.enumerated() {
            pairs.append((.agent(agent.key), .jira("ACME-\(index % 120)")))
            pairs.append((.agent(agent.key), LinkTargets.pullRequest("acme-com/api#\(index % 200 + 1)")!))
            pairs.append((.agent(agent.key), .branch("api:NI/ACME-\(index % 150)")))
        }
        pairs += (0..<100).map { (LinkTargets.pullRequest("acme-com/api#\($0 + 1)")!, LinkEntity.jira("ACME-\($0)")) }
        let table = linkedTable(pairs)
        let begin = Date()
        let index = AgentLinkIndex(table: table)
        let keys = ["acme-7", "api#9", "export"].map { AgentSearch.linkedKeys(query: $0, agents: agents, links: index) }
        check(!keys[0].isEmpty && !keys[1].isEmpty && keys[2].isEmpty, "found")
        check(Date().timeIntervalSince(begin) < 2, "fast")
    }),
]
