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
        check(table.allLinks.count == 1, "A-B and B-A are one row")
        let link = table.allLinks[0]
        check(link.fromEntity.uuidString < link.toEntity.uuidString && Set([link.fromEntity, link.toEntity]) == [table.uuid(of: ticket)!, table.uuid(of: pr7)!], "canonical order: \(link)")
        check(table.allEntities.count == 2, "one entity per end")
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
        check(table.link(pair)?.source == .manual, "manual wins")
        table.upsert(pair, source: .auto, now: start.addingTimeInterval(20 * day))
        check(table.link(pair)?.source == .manual, "auto does not turn it back")
        table.remove(pair, now: start.addingTimeInterval(30 * day))
        check(table.link(pair)?.removed == true && table.neighbors(of: agent).isEmpty, "removed, kept as a row")
        check(!table.upsert(pair, source: .auto, now: start.addingTimeInterval(40 * day)) && table.neighbors(of: agent).isEmpty, "auto does not re-add")
        table.upsert(pair, source: .manual, now: start.addingTimeInterval(50 * day))
        check(table.neighbors(of: agent) == [ticket], "adding by hand revives it")
        var fresh = LinkTable()
        fresh.remove(LinkPair(agent, other), now: start)
        check(!fresh.upsert(LinkPair(agent, other), source: .auto, now: start) && fresh.allLinks.count == 1, "removing a link never seen blocks it too")
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
        check(later.link(LinkPair(agent, pr7)) == nil, "stale auto dropped")
        check(later.link(LinkPair(agent, ticket)) == nil, "touched at day 2 but 93 days ago")
        check(later.link(LinkPair(agent, other)) != nil && later.link(LinkPair(agent, pr8))?.removed == true, "manual and removed kept")
        check(table.pruned(now: start.addingTimeInterval(10 * day)) == table, "nothing dropped early")
    }),
    ("links: the file round trips and a missing or corrupt file is an empty table", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket)], now: start)
        table.remove(LinkPair(ticket, pr7), now: start)
        let decoded = LinkTables.decode(LinkTables.encode(table))
        check(decoded == table, "round trip")
        check(LinkTables.decode(nil).allLinks.isEmpty && LinkTables.decode(Data("{nope".utf8)).allLinks.isEmpty, "tolerated")
        check(String(decoding: LinkTables.encode(table) ?? Data(), as: UTF8.self).contains("\"kind\" : \"jira\""), "entities with kinds as strings")
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
            check(LinkStore(file: file).table.allLinks.isEmpty, "corrupt file")
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
    ("links: the repo comes from the origin remote, for ssh and https, also in a renamed checkout and a worktree", {
        check(LinkBranches.repo(config: "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:acme-com/orbit.api.git\n\tfetch = x\n") == "orbit.api", "ssh")
        check(LinkBranches.repo(config: "[remote \"upstream\"]\n\turl = https://github.com/x/wrong.git\n[remote \"origin\"]\n\turl = https://github.com/acme-com/orbit.web\n") == "orbit.web", "https, origin only")
        check(LinkBranches.repo(config: "[remote \"origin\"]\n\turl = git@example.com:a/b.git\n") == nil && LinkBranches.repo(config: "") == nil, "not github")
        let root = tempDirectory()
        let main = root.appendingPathComponent("renamed-checkout")
        let dotGit = main.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: dotGit.appendingPathComponent("worktrees/wt"), withIntermediateDirectories: true)
        try "ref: refs/heads/NI/ACME-1\n".write(to: dotGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "[remote \"origin\"]\n\turl = git@github.com:acme-com/orbit.api.git\n".write(to: dotGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: main.path) == "orbit.api:NI/ACME-1", "a renamed checkout")
        let worktree = root.appendingPathComponent("orbit.api-wt-x")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(dotGit.path)/worktrees/wt\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/other\n".write(to: dotGit.appendingPathComponent("worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: dotGit.appendingPathComponent("worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: worktree.path) == "orbit.api:other", "a worktree through commondir")
        let bare = root.appendingPathComponent("noremote")
        try FileManager.default.createDirectory(at: bare.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/x\n".write(to: bare.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        check(LinkBranches.current(folder: bare.path) == "noremote:x", "the folder name without a remote")
    }),
    ("links: an agent is linked to the head branch of its pull request, by the pull request's repo", {
        let listed = GitHubPR(url: "https://github.com/acme-com/orbit.api/pull/7", number: 7, title: "ACME-1: x", repo: "acme-com/orbit.api", updated: start, head: "NI/ACME-1")
        let withPR = state("topic:a", prURL: "acme-com/orbit.api#7", folder: "/nonexistent/other-name")
        let pairs = LinkDerivation.pairs(states: [withPR], pullRequests: [listed], context: LinkContext(projects: projects))
        check(pairs.contains(LinkPair(.agent("topic:a"), .branch("orbit.api:NI/ACME-1"))), "\(pairs)")
        check(Set(pairs).count == pairs.count, "no duplicate pairs")
        let unknown = LinkDerivation.pairs(states: [withPR], pullRequests: [], context: LinkContext(projects: projects))
        check(!unknown.contains { $0.second.kind == .branch }, "no head known, no branch")
    }),
    ("links: an agent in a parent folder is linked to the branches of its ticket, up to five", {
        var parent = state("topic:00000000-0000-0000-0000-000000000002", folder: "/nonexistent/parent")
        parent.jiraKey = "ACME-1"
        func listed(_ number: Int) -> GitHubPR {
            GitHubPR(url: "https://github.com/acme-com/orbit.api/pull/\(number)", number: number, title: "x", repo: "acme-com/orbit.api", updated: start, head: "NI/ACME-1-\(number)")
        }
        let few = LinkDerivation.pairs(states: [parent], pullRequests: [listed(1), listed(2)], context: LinkContext(projects: projects))
        let branches = Set(few.filter { $0.first == .agent("topic:00000000-0000-0000-0000-000000000002") && $0.second.kind == .branch }.map(\.second))
        check(branches == [.branch("orbit.api:NI/ACME-1-1"), .branch("orbit.api:NI/ACME-1-2")], "\(branches)")
        check(Set(few).count == few.count, "no duplicate pairs")
        let many = LinkDerivation.pairs(states: [parent], pullRequests: (1...6).map(listed), context: LinkContext(projects: projects))
        check(!many.contains { $0.first == .agent("topic:00000000-0000-0000-0000-000000000002") && $0.second.kind == .branch }, "more than five is noise")
        var none = parent
        none.jiraKey = nil
        check(!LinkDerivation.pairs(states: [none], pullRequests: [listed(1)], context: LinkContext(projects: projects)).contains { $0.first.kind == .agent }, "no ticket, no branch")
    }),
    ("links: rows by agent, ticket and pull request, with status from the lookup cache and the two-hop ones", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8), LinkPair(pr7, other)], now: start)
        table.upsert(LinkPair(agent, pr8), source: .manual, now: start)
        var labels = LinkLabels(agents: [agent.id: "Export case"])
        labels.infos[SessionRef.jira("ACME-1").cacheKey] = SessionRefInfo(title: "Export", status: "Done", category: "done")
        labels.infos[SessionRef.pullRequest(repo: "acme-com/orbit.api", number: 7).cacheKey] = SessionRefInfo(title: "Export it", state: "merged")
        let byAgent = LinkRows.rows(table, mode: .agent, labels: labels, including: [.agent("main"), agent])
        check(Set(byAgent.map(\.id)) == [table.uuid(of: agent)!.uuidString, "agent:main"], "agents, including one without links: \(byAgent.map(\.id))")
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
        check(Set(byAgent.map(\.id)).count == byAgent.count && row.chips.map(\.id) == row.chips.compactMap { table.uuid(of: $0.entity) }, "stable unique ids")
    }),
    ("links: the first file format is converted once, the original kept, and the result is stable", {
        let old = Data(#"""
        {"version":1,"edges":[
         {"fromKind":"agent","fromID":"main","toKind":"jira","toID":"ACME-1","source":"auto","removed":false,"createdAt":"2026-11-01T10:00:00Z","lastSeenAt":"2026-11-10T10:00:00Z"},
         {"fromKind":"github_pr","fromID":"acme-com/orbit.api#7","toKind":"jira","toID":"ACME-1","source":"manual","removed":true,"createdAt":"2026-11-02T10:00:00Z","lastSeenAt":"2026-11-03T10:00:00Z"}]}
        """#.utf8)
        let loaded = LinkTables.load(old)
        check(loaded.migrated && loaded.table.allEntities.count == 3 && loaded.table.allLinks.count == 2, "entities and links")
        check(loaded.table.neighbors(of: ticket) == [.agent("main")] && loaded.table.link(LinkPair(pr7, ticket))?.removed == true && loaded.table.link(LinkPair(pr7, ticket))?.source == .manual, "source and removal kept")
        let kept = loaded.table.link(LinkPair(.agent("main"), ticket))
        check(kept?.createdAt == ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z") && kept?.lastSeenAt == ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z"), "dates kept")
        let again = LinkTables.load(LinkTables.encode(loaded.table))
        check(!again.migrated && again.table == loaded.table, "the new file reads back as itself")
        MainActor.assumeIsolated {
            let file = tempDirectory().appendingPathComponent("links.json")
            try? old.write(to: file)
            let store = LinkStore(file: file, now: ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!)
            let backup = file.deletingLastPathComponent().appendingPathComponent(LinkTables.backupName)
            check((try? Data(contentsOf: backup)) == old, "the old file is kept as links.v1.json")
            check(!LinkTables.load(try? Data(contentsOf: file)).migrated && LinkTables.load(try? Data(contentsOf: file)).table == store.table, "links.json is in the new format")
            let ids = store.table.allEntities.map(\.id)
            check(LinkStore(file: file, now: start).table.allEntities.map(\.id) == ids, "a second launch changes no uuid")
        }
    }),
    ("links: renaming keeps the old id as an alias that still resolves", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7)], now: start)
        let id = table.uuid(of: ticket)!
        check(table.rename(ticket, to: "NEW-9") && !table.rename(ticket, to: "NEW-9"), "renamed once")
        let moved = LinkEntity.jira("NEW-9")
        check(table.uuid(of: moved) == id && table.uuid(of: ticket) == id, "both ids resolve to the same uuid")
        check(table.record(moved)?.aliases == ["ACME-1"] && table.record(moved)?.ref == "NEW-9", "ref and alias")
        check(table.neighbors(of: ticket) == [agent, pr7] && table.neighbors(of: moved) == [agent, pr7], "links follow")
        check(table.neighbors(of: agent) == [moved] && table.allEntities.count == 3 && table.allLinks.count == 2, "nothing duplicated: \(table.neighbors(of: agent))")
        check(!table.upsert(LinkPair(agent, ticket), source: .auto, now: start) && table.allLinks.count == 2, "linking by the old key finds the existing link")
        check(table.upsert(LinkPair(pr8, ticket), source: .auto, now: start) && table.record(moved) != nil && table.allEntities.count == 4, "a new link by the old key attaches to the renamed entity")
        check(!table.upsert(LinkPair(ticket, moved), source: .auto, now: start), "an entity is not linked to its own alias")
        check(table.rename(moved, to: "ACME-1") && table.record(ticket)?.ref == "ACME-1" && table.record(ticket)?.aliases == ["NEW-9"], "renamed back")
        check(!table.rename(LinkEntity.jira("NOPE-1"), to: "X-1"), "an unknown entity")
        let reloaded = LinkTables.decode(LinkTables.encode(table))
        check(reloaded == table && reloaded.uuid(of: moved) == id, "aliases survive the file")
    }),
    ("links: renaming onto an existing entity merges the two, manual beating auto and duplicate pairs dropped", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(other, pr8)], now: start)
        table.upsert(LinkPair(agent, other), source: .manual, now: start)
        table.upsert(LinkPair(other, pr7), source: .auto, now: start)
        table.remove(LinkPair(pr7, ticket), now: start)
        table.upsert(LinkPair(pr7, ticket), source: .manual, now: start)
        table.remove(LinkPair(pr7, ticket), now: start)
        table.upsert(LinkPair(other, pr7), source: .manual, now: start)
        table.remove(LinkPair(other, pr7), now: start)
        let keep = table.uuid(of: other)!
        let gone = table.uuid(of: ticket)!
        check(table.rename(ticket, to: "ACME-2"), "merged")
        check(table.uuid(of: ticket) == keep && table.uuid(of: other) == keep && table.entities[gone] == nil, "the entity at the new ref stays")
        check(table.record(other)?.aliases == ["ACME-1"], "the old ref became an alias: \(String(describing: table.record(other)?.aliases))")
        check(table.link(LinkPair(other, agent))?.source == .manual, "agent link: the manual one wins over the auto one")
        check(table.link(LinkPair(other, pr7))?.source == .manual && table.link(LinkPair(other, pr7))?.removed == true, "both removals stay removed")
        check(table.link(LinkPair(other, ticket)) == nil && table.neighbors(of: other) == [agent, pr8].sorted(), "no link to itself: \(table.neighbors(of: other))")
        check(table.allLinks.count == Set(table.allLinks.map(\.ends)).count, "every pair once")
        check(table.allLinks.allSatisfy { table.entities[$0.fromEntity] != nil && table.entities[$0.toEntity] != nil }, "no link points at the removed uuid")
    }),
    ("links: stale auto links are dropped after 90 days together with the entities they leave behind", {
        var table = LinkTable()
        table.upsert(LinkPair(agent, ticket), source: .auto, now: start)
        table.upsert(LinkPair(pr7, pr8), source: .manual, now: start)
        let later = table.pruned(now: start.addingTimeInterval(91 * day))
        check(later.neighbors(of: agent).isEmpty && later.uuid(of: agent) == nil && later.uuid(of: ticket) == nil, "stale auto link and its entities")
        check(later.neighbors(of: pr7) == [pr8] && later.allEntities.count == 2, "manual kept")
        check(table.pruned(now: start.addingTimeInterval(89 * day)) == table, "kept before 90 days")
    }),
    ("links: the MCP tool lists neighbors and related, and is read-only", {
        var table = LinkTable()
        table.ingest([LinkPair(agent, ticket), LinkPair(ticket, pr7), LinkPair(ticket, pr8)], now: start)
        let labels = LinkLabels(agents: [agent.id: "Export case"])
        let text = LinkTables.markdown(table, entity: agent, depth: 2, labels: labels)
        let ticketID = table.uuid(of: ticket)!.uuidString
        let prID = table.uuid(of: pr7)!.uuidString
        check(text.contains("`jira:ACME-1` `\(ticketID)` (auto)") && text.contains("`github_pr:acme-com/orbit.api#7` `\(prID)` orbit.api#7 via `jira:ACME-1`"), text)
        check(!LinkTables.markdown(table, entity: agent, depth: 1, labels: labels).contains("Related"), "depth 1")
        check(LinkTables.markdown(table, entity: ticket, depth: 1, kind: .githubPR, labels: labels).contains("Linked (2)"), "kind filter")
        check(LinkTables.markdown(table, entity: nil, depth: 1, labels: labels).contains("3 links"), "everything")
        check(text.contains(table.uuid(of: ticket)!.uuidString) && text.hasPrefix("# `agent:"), "uuids in the answer")
        var renamed = table
        renamed.rename(ticket, to: "NEW-1")
        let asked = LinkTables.markdown(renamed, entity: ticket, depth: 1, labels: labels)
        check(asked.contains("# `jira:NEW-1`") && asked.contains("Also known as: `ACME-1`"), "an old key finds the renamed entity: \(asked)")
        check(LinkTables.markdown(LinkTable(), entity: ticket, depth: 1, labels: labels).contains("No links"), "empty")
        check(MCPServer.allTools.first { $0.name == "links" }?.readOnly == true, "read-only")
    }),
]
