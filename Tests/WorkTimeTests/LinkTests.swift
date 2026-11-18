import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let start = Date(timeIntervalSince1970: 1_792_300_000)
private let day: TimeInterval = 86400
private let ticket = LinkEntity.jira("acme-1")
private let other = LinkEntity.jira("ACME-2")
private let agent = LinkEntity.agent("topic:\(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!.uuidString)")
private let pr7 = LinkTargets.pullRequest("acme-com/orbit.api#7")!
private let pr8 = LinkTargets.pullRequest("https://github.com/acme-com/orbit.api/pull/8")!
private let projects: Set<String> = ["ACME"]

private func state(_ key: String, title: String = "agent", prURL: String? = nil, folder: String? = nil) -> AgentState {
    AgentState(key: key, title: title, prURL: prURL, folder: folder, status: .idle)
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let linkTests: [(name: String, run: () throws -> Void)] = [
    ("links: ids are normalized and an edge is one row whichever end comes first", {
        check(ticket.id == "ACME-1" && pr7.id == "acme-com/orbit.api#7" && pr8.id == "acme-com/orbit.api#8", "ids")
        check(LinkTargets.branch(repo: "acme-com/orbit.api", name: " NI/ACME-1 ")?.id == "orbit.api:NI/ACME-1", "branch")
        check(LinkTargets.slack("https://acme.slack.com/archives/C1/p123")?.kind == .slackThread && LinkTargets.slack("https://example.com/x") == nil, "slack")
        check(LinkTargets.parse("github_pr:acme-com/orbit.api#7") == pr7 && LinkTargets.parse("acme-2") == other && LinkTargets.parse("jira:acme-2") == other, "parse")
        check(LinkEntity(key: "branch:orbit.api:NI/x")?.id == "orbit.api:NI/x" && LinkEntity(key: "nope") == nil, "key")
        var table = LinkTable()
        table.upsert(LinkPair(ticket, pr7), source: .auto, now: start)
        table.upsert(LinkPair(pr7, ticket), source: .auto, now: start)
        check(table.all.count == 1, "A-B and B-A are one row")
        check(table.all[0].from == ticket && table.all[0].to == pr7, "the smaller end is from: \(table.all[0])")
        check(!table.upsert(LinkPair(ticket, ticket), source: .auto, now: start), "no self links")
    }),
    ("links: neighbors are found from both ends, by kind", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8), LinkPair(pr7, other)], now: start)
        check(table.neighbors(of: ticket) == [agent, pr7, pr8], "ticket: \(table.neighbors(of: ticket))")
        check(table.neighbors(of: ticket, kind: .githubPR) == [pr7, pr8], "kind filter")
        check(table.neighbors(of: pr7) == [ticket, other].sorted(), "a pull request with two tickets")
        check(table.neighbors(of: agent) == [ticket], "the other direction")
        check(table.entities(kind: .githubPR) == [pr7, pr8], "entities")
    }),
    ("links: related walks two hops once each and survives a cycle", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8), LinkPair(pr7, other), LinkPair(other, agent)], now: start)
        let reach = table.related(to: agent, depth: 2)
        check(Set(reach.map(\.entity)) == [ticket, other, pr7, pr8], "\(reach)")
        check(reach.filter { $0.depth == 1 }.map(\.entity).sorted() == [ticket, other].sorted(), "direct ones first")
        check(reach.first { $0.entity == pr8 }?.via == ticket && reach.allSatisfy { $0.entity != agent }, "via, and never the start")
        check(table.related(to: agent, depth: 1).count == 2, "depth 1")
    }),
    ("links: a manual link wins over auto and a removal stops auto from adding it again", {
        var table = LinkTable()
        let pair = LinkPair(agent, ticket)
        table.upsert(pair, source: .auto, now: start)
        table.upsert(pair, source: .manual, now: start.addingTimeInterval(10))
        check(table.edge(pair)?.source == .manual, "manual wins")
        table.upsert(pair, source: .auto, now: start.addingTimeInterval(20 * day))
        check(table.edge(pair)?.source == .manual, "auto does not turn it back")
        table.remove(pair, now: start.addingTimeInterval(30 * day))
        check(table.edge(pair)?.removed == true && table.neighbors(of: agent).isEmpty, "removed, kept as a row")
        check(!table.upsert(pair, source: .auto, now: start.addingTimeInterval(40 * day)) && table.neighbors(of: agent).isEmpty, "auto does not re-add")
        table.upsert(pair, source: .manual, now: start.addingTimeInterval(50 * day))
        check(table.neighbors(of: agent) == [ticket], "adding by hand revives it")
        var fresh = LinkTable()
        fresh.remove(LinkPair(agent, other), now: start)
        check(!fresh.upsert(LinkPair(agent, other), source: .auto, now: start) && fresh.all.count == 1, "removing a link never seen blocks it too")
    }),
    ("links: a steady table does not change and stale auto links are dropped after 90 days", {
        var table = LinkTable()
        table.upsert(LinkPair(agent, ticket), source: .auto, now: start)
        check(!table.upsert(LinkPair(agent, ticket), source: .auto, now: start.addingTimeInterval(60)), "no change inside a day")
        check(table.upsert(LinkPair(agent, ticket), source: .auto, now: start.addingTimeInterval(2 * day)), "touched after a day")
        table.upsert(LinkPair(agent, pr7), source: .auto, now: start)
        table.upsert(LinkPair(agent, other), source: .manual, now: start)
        table.remove(LinkPair(agent, pr8), now: start)
        let later = table.pruned(now: start.addingTimeInterval(95 * day))
        check(later.edge(LinkPair(agent, pr7)) == nil, "stale auto dropped")
        check(later.edge(LinkPair(agent, ticket)) == nil, "touched at day 2 but 93 days ago")
        check(later.edge(LinkPair(agent, other)) != nil && later.edge(LinkPair(agent, pr8))?.removed == true, "manual and removed kept")
        check(table.pruned(now: start.addingTimeInterval(10 * day)) == table, "nothing dropped early")
    }),
    ("links: the file round trips and a missing or corrupt file is an empty table", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket)], now: start)
        table.remove(LinkPair(ticket, pr7), now: start)
        let decoded = LinkTables.decode(LinkTables.encode(table))
        check(decoded == table, "round trip")
        check(LinkTables.decode(nil).all.isEmpty && LinkTables.decode(Data("{nope".utf8)).all.isEmpty, "tolerated")
        check(String(decoding: LinkTables.encode(table) ?? Data(), as: UTF8.self).contains("\"fromKind\" : \"jira\""), "one row per link with kinds as strings")
        let unknown = Data(#"{"version":1,"edges":[{"fromKind":"zoom","fromID":"1","toKind":"jira","toID":"ACME-1","source":"auto","removed":false,"createdAt":"2026-11-18T10:00:00Z","lastSeenAt":"2026-11-18T10:00:00Z"}]}"#.utf8)
        check(LinkTables.decode(unknown).neighbors(of: ticket).first?.kind.rawValue == "zoom", "a new kind needs no migration")
    }),
    ("links: the store keeps the table on disk, prunes on load and survives a corrupt file", {
        MainActor.assumeIsolated {
            let file = tempDirectory().appendingPathComponent("links.json")
            let store = LinkStore(file: file, now: start)
            store.ingest([LinkPair(agent, ticket)], now: start)
            store.add(LinkPair(agent, pr7), now: start)
            store.remove(LinkPair(agent, ticket), now: start)
            Thread.sleep(forTimeInterval: 0.5)
            let again = LinkStore(file: file, now: start.addingTimeInterval(day))
            check(again.table.neighbors(of: agent) == [pr7], "reloaded")
            check(LinkStore(file: file, now: start.addingTimeInterval(200 * day)).table.neighbors(of: agent) == [pr7], "manual outlives the cutoff")
            try? Data("garbage".utf8).write(to: file)
            check(LinkStore(file: file).table.all.isEmpty, "corrupt file")
        }
    }),
    ("links: an agent is linked to its ticket, pull requests, branch and thread", {
        var topic = state("topic:00000000-0000-0000-0000-000000000001", title: "Case")
        topic.jiraKey = "acme-5"
        topic.slackURL = "https://acme.slack.com/archives/C1/p9"
        topic.pullRequests = ["https://github.com/acme-com/orbit.api/pull/7", "acme-com/orbit.web#9"]
        topic.sessionPR = "https://github.com/acme-com/orbit.api/pull/8"
        var context = LinkContext(projects: projects)
        context.branches[topic.key] = "orbit.api:NI/ACME-6-export"
        let ends = Set(LinkDerivation.pairs(for: topic, context: context).map { $0.second })
        check(ends == [.jira("ACME-5"), .jira("ACME-6"), pr7, pr8, LinkTargets.pullRequest("acme-com/orbit.web#9")!,
                       .slack("https://acme.slack.com/archives/C1/p9"), .branch("orbit.api:NI/ACME-6-export")], "\(ends)")
        check(LinkDerivation.pairs(for: topic, context: context).contains(LinkPair(.branch("orbit.api:NI/ACME-6-export"), .jira("ACME-6"))), "the branch names its ticket")
    }),
    ("links: a pull request's agent follows the ticket in the pull request's title", {
        let agentState = state("https://github.com/acme-com/orbit.api/pull/7", title: "x", prURL: "https://github.com/acme-com/orbit.api/pull/7")
        let context = LinkContext(projects: projects, titles: ["https://github.com/acme-com/orbit.api/pull/7": "ACME-1: Export"])
        let ends = Set(LinkDerivation.pairs(for: agentState, context: context).map { $0.second })
        check(ends == [ticket, pr7], "\(ends)")
        check(LinkDerivation.pairs(for: state("main"), context: context).isEmpty, "an agent with nothing")
    }),
    ("links: pull requests are linked to tickets and branches without any agent, a pull request with two tickets included", {
        let pairs = LinkDerivation.pairs(pullRequest: "https://github.com/acme-com/orbit.api/pull/7", title: "ACME-1 and ACME-2: Export", head: "NI/ACME-3-x", projects: projects)
        let ends = Set(pairs.flatMap { [$0.first, $0.second] }).subtracting([pr7])
        check(ends == [.jira("ACME-1"), .jira("ACME-2"), .jira("ACME-3"), .branch("orbit.api:NI/ACME-3-x")], "\(ends)")
        check(pairs.contains(LinkPair(.branch("orbit.api:NI/ACME-3-x"), .jira("ACME-3"))), "branch to ticket")
        let listed = GitHubPR(url: "https://github.com/acme-com/orbit.api/pull/8", number: 8, title: "ACME-4: x", repo: "acme-com/orbit.api", updated: start, head: "main")
        check(LinkDerivation.pairs(for: listed, projects: projects).contains(LinkPair(pr8, .branch("orbit.api:main"))), "from the cached list")
        let event = GitHubEvent(event: "pull_request", action: "opened", repo: "acme-com/orbit.api", number: 7, title: "ACME-9: y", headRef: "NI/ACME-9")
        check(LinkDerivation.pairs(for: event, projects: projects).contains(LinkPair(pr7, .jira("ACME-9"))), "from the live event")
        check(LinkDerivation.pairs(for: GitHubEvent(event: "ping"), projects: projects).isEmpty, "an event about nothing")
        check(LinkDerivation.pairs(pullRequest: "https://github.com/acme-com/orbit.api/pull/7", title: "ACME-1", head: nil, projects: []).isEmpty, "no projects, no tickets")
    }),
    ("links: events decode the head branch", {
        let event = try? JSONDecoder().decode(GitHubEvent.self, from: Data(#"{"event":"pull_request","repo":"a/b","number":3,"title":"t","head_ref":"NI/X-1"}"#.utf8))
        check(event?.headRef == "NI/X-1" && event?.title == "t", "head_ref")
    }),
    ("links: the branch of a folder is read from HEAD, also in a worktree", {
        let root = tempDirectory()
        let repo = root.appendingPathComponent("orbit.api")
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("worktrees/wt"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "ref: refs/heads/NI/ACME-1\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: repo.path) == "orbit.api:NI/ACME-1" && LinkBranches.current(folder: repo.appendingPathComponent("src").path) == "orbit.api:NI/ACME-1", "plain")
        let worktree = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(git.path)/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/other\n".write(to: git.appendingPathComponent("worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: worktree.path) == "orbit.api:other", "worktree: \(String(describing: LinkBranches.current(folder: worktree.path)))")
        try "0123abcd\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: repo.path) == nil && LinkBranches.current(folder: nil) == nil && LinkBranches.current(folder: "/nonexistent/x") == nil, "detached or none")
    }),
    ("links: rows by agent, ticket and pull request, with status from the lookup cache and the two-hop ones", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8), LinkPair(pr7, other)], now: start)
        table.upsert(LinkPair(agent, pr8), source: .manual, now: start)
        var labels = LinkLabels(agents: [agent.id: "Export case"])
        labels.infos[SessionRef.jira("ACME-1").cacheKey] = SessionRefInfo(title: "Export", status: "Done", category: "done")
        labels.infos[SessionRef.pullRequest(repo: "acme-com/orbit.api", number: 7).cacheKey] = SessionRefInfo(title: "Export it", state: "merged")
        let byAgent = LinkRows.rows(table, mode: .agent, labels: labels, including: [.agent("main"), agent])
        check(byAgent.map(\.id) == [agent.key, "agent:main"] || byAgent.map(\.id) == ["agent:main", agent.key], "agents, including one without links: \(byAgent.map(\.id))")
        let row = byAgent.first { $0.entity == agent }!
        check(row.chips.map(\.entity) == [ticket, pr8], "chips: \(row.chips)")
        check(row.chips.first { $0.entity == pr8 }?.source == .manual && row.chips.first { $0.entity == ticket }?.source == .auto, "manual and auto")
        check(row.related.map(\.entity) == [pr7], "two hops: \(row.related)")
        let byTicket = LinkRows.rows(table, mode: .ticket, labels: labels)
        check(byTicket.map(\.entity) == [ticket, other], "tickets: \(byTicket.map(\.id))")
        check(byTicket[0].chips.map(\.entity) == [agent, pr7, pr8], "a ticket's agents and pull requests")
        check(LinkRows.rows(table, mode: .pullRequest, labels: labels).first { $0.entity == pr7 }?.chips.map(\.entity) == [ticket, other].sorted(), "a pull request's tickets")
        check(labels.status(ticket)?.text == "Done" && labels.status(ticket)?.kind == .done && labels.status(pr7)?.text == "merged" && labels.status(pr8) == nil, "status pills")
        check(LinkRows.rows(table, mode: .ticket, labels: labels, query: "acme-1").map(\.entity) == [ticket], "search")
        check(LinkRows.rows(table, mode: .ticket, labels: labels, query: "zzz").isEmpty, "no match")
        check(Set(byAgent.map(\.id)).count == byAgent.count, "stable unique ids")
    }),
    ("links: the MCP tool lists neighbors and related, and is read-only", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8)], now: start)
        let labels = LinkLabels(agents: [agent.id: "Export case"])
        let text = LinkTables.markdown(table, entity: agent, depth: 2, labels: labels)
        check(text.contains("`jira:ACME-1` (auto)") && text.contains("`github_pr:acme-com/orbit.api#7` orbit.api#7 via `jira:ACME-1`"), text)
        check(!LinkTables.markdown(table, entity: agent, depth: 1, labels: labels).contains("Related"), "depth 1")
        check(LinkTables.markdown(table, entity: ticket, depth: 1, kind: .githubPR, labels: labels).contains("Linked (2)"), "kind filter")
        check(LinkTables.markdown(table, entity: nil, depth: 1, labels: labels).contains("3 links"), "everything")
        check(LinkTables.markdown(LinkTable(), entity: ticket, depth: 1, labels: labels).contains("No links"), "empty")
        check(MCPServer.allTools.first { $0.name == "links" }?.readOnly == true, "read-only")
    }),
]
