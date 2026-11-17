import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let projects: Set<String> = ["ACME", "ORB"]
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func pr(_ number: Int, repo: String = "acme-com/orbit.api") -> SessionRef { .pullRequest(repo: repo, number: number) }

private func tool(_ id: String, _ summary: String, detail: String = "", result: String?) -> AgentItem {
    AgentItem(id: id, kind: .tool(name: "mcp__worktime__jira_issue", summary: summary, detail: detail, result: result, isError: false, auto: true))
}

private func entry(_ info: SessionRefInfo?, age: TimeInterval = 0) -> SessionRefEntry { SessionRefEntry(info: info, fetched: now.addingTimeInterval(-age)) }

private func plan(_ refs: [SessionRef], skip: Set<String> = [], cache: [String: SessionRefEntry] = [:], backoff: [String: Date] = [:],
                  inFlight: Set<String> = []) -> SessionRefLookup.Plan {
    SessionRefLookup.plan(refs, skip: skip, cache: cache, backoff: backoff, inFlight: inFlight, now: now)
}

let sessionRefLookupTests: [(name: String, run: () throws -> Void)] = [
    ("session titles: jira_issue names its ticket in the heading and the linked ones with their status", {
        let result = "# ACME-12 Export the customer list\nStory \u{00B7} In Progress \u{00B7} priority High\nAssignee: Sam\n\n## Linked issues\n"
            + "- blocks ACME-13 Fix the export header (Done)\n- is blocked by ORB-4 Upgrade the parser (To Do)\n"
        let found = SessionTitles.structured(call: "ACME-12", result: result, projects: projects)
        check(found[.jira("ACME-12")]?.title == "Export the customer list", "\(found)")
        check(found[.jira("ACME-13")] == SessionRefInfo(title: "Fix the export header", status: "Done"), "\(String(describing: found[.jira("ACME-13")]))")
        check(found[.jira("ORB-4")]?.status == "To Do", "relation with several words")
    }),
    ("session titles: jira_search lines carry the status after the title, and only the configured projects count", {
        let result = "2 issues for assignee = me\n- ACME-5 Add the retry button \u{00B7} In Review \u{00B7} High \u{00B7} updated 2 days ago\n  https://example.atlassian.net/browse/ACME-5\n"
            + "- OTHER-9 Not ours \u{00B7} Done \u{00B7} Low\n"
        let found = SessionTitles.structured(call: "", result: result, projects: projects)
        check(found[.jira("ACME-5")] == SessionRefInfo(title: "Add the retry button", status: "In Review"), "\(found)")
        check(found.count == 1, "other project ignored")
    }),
    ("session titles: github_pr and github_prs name the pull request, its state and whether it is a draft", {
        let detail = "# acme-com/orbit.api#7 Add the export endpoint\nhttps://github.com/acme-com/orbit.api/pull/7\n\n- State: merged, by sam\n- Branches: a into main\n"
        let one = SessionTitles.structured(call: "acme-com/orbit.api#7", result: detail, projects: projects)
        check(one[pr(7)] == SessionRefInfo(title: "Add the export endpoint", state: "merged"), "\(one)")
        let list = "- acme-com/orbit.api#8 Speed up the search\n  https://github.com/acme-com/orbit.api/pull/8\n  draft \u{00B7} by sam \u{00B7} no review decision\n"
            + "- acme-com/orbit.web#9 Closed idea\n  https://github.com/acme-com/orbit.web/pull/9\n  closed \u{00B7} by kim \u{00B7} updated 3 days ago\n"
            + "- acme-com/orbit.web#10 Plain\n  https://github.com/acme-com/orbit.web/pull/10\n  by kim \u{00B7} updated now\n"
        let many = SessionTitles.structured(call: "", result: list, projects: projects)
        check(many[pr(8)] == SessionRefInfo(title: "Speed up the search", state: "open", isDraft: true), "\(String(describing: many[pr(8)]))")
        check(many[pr(9, repo: "acme-com/orbit.web")]?.state == "closed", "closed")
        check(many[pr(10, repo: "acme-com/orbit.web")]?.state == "open", "open when the line names none")
    }),
    ("session titles: gh JSON with an address, and without one by the pull request the call named", {
        let withURL = #"[{"title":"Add retries","number":3,"url":"https://github.com/acme-com/orbit.api/pull/3","state":"OPEN","isDraft":true}]"#
        let a = SessionTitles.structured(call: "gh pr list", result: withURL, projects: projects)
        check(a[pr(3)] == SessionRefInfo(title: "Add retries", state: "open", isDraft: true), "\(a)")
        let bare = #"{"title":"Rename the flag","state":"MERGED","isDraft":false}"#
        let b = SessionTitles.structured(call: "gh pr view https://github.com/acme-com/orbit.api/pull/11 --json title,state", result: bare, projects: projects)
        check(b[pr(11)] == SessionRefInfo(title: "Rename the flag", state: "merged"), "\(b)")
        let two = SessionTitles.structured(call: "gh pr view https://github.com/acme-com/orbit.api/pull/11 https://github.com/acme-com/orbit.api/pull/12", result: bare, projects: projects)
        check(two.isEmpty, "two pull requests named: not guessed")
        let numbered = #"{"title":"By number","number":12,"mergedAt":"2026-01-01T00:00:00Z"}"#
        let c = SessionTitles.structured(call: "gh pr list https://github.com/acme-com/orbit.api/pull/11 https://github.com/acme-com/orbit.api/pull/12", result: numbered, projects: projects)
        check(c[pr(12)] == SessionRefInfo(title: "By number", state: "merged"), "\(c)")
    }),
    ("session titles: Jira's own JSON gives the summary, status and its category", {
        let result = #"{"issues":[{"key":"ACME-21","fields":{"summary":"Show the balance","status":{"name":"Resolved","statusCategory":{"key":"done"}}}},{"key":"NOPE-1","fields":{"summary":"Elsewhere"}}]}"#
        let found = SessionTitles.structured(call: "", result: result, projects: projects)
        check(found[.jira("ACME-21")] == SessionRefInfo(title: "Show the balance", status: "Resolved", category: "done"), "\(found)")
        check(found.count == 1, "project not configured")
    }),
    ("session titles: text that is not an answer about a ticket gives nothing", {
        check(SessionTitles.structured(call: "ls", result: "total 3\nfile.txt\nnotes", projects: projects).isEmpty, "plain")
        check(SessionTitles.structured(call: "", result: "{not json", projects: projects).isEmpty, "broken json")
        check(SessionTitles.structured(call: "", result: #"{"title":"A title"}"#, projects: projects).isEmpty, "no pull request named")
    }),
    ("session titles: a ticket named with its title in running text is a hint, in a few written forms", {
        let text = "Commit abc1234 ACME-12: Export the customer list\nSee ORB-4 - Upgrade the parser now\nAlso ACME-12: A second time\nACME-30: short"
            + "\nACME-31: https://example.atlassian.net/browse/ACME-31 and more"
        let found = SessionTitles.hints(in: text, projects: projects)
        check(found[.jira("ACME-12")] == "Export the customer list", "first one wins: \(found)")
        check(found[.jira("ORB-4")] == "Upgrade the parser now", "dash")
        check(found[.jira("ACME-30")] == nil, "too short to be a title")
        check(found[.jira("ACME-31")] == nil, "a link is not a title")
        check(SessionTitles.hints(in: text, projects: []).isEmpty, "no projects")
    }),
    ("session titles: a title loses its Markdown and is cut at the limit", {
        check(SessionTitles.clean("**Fix `the` thing** http://a/b", limit: 50) == "Fix the thing", SessionTitles.clean("**Fix `the` thing** http://a/b", limit: 50))
        check(SessionTitles.clean("Fix [the thing](http://a/b) now", limit: 50) == "Fix the thing now", "link words kept")
        check(SessionTitles.clean("[WIP] Draft work", limit: 50) == "[WIP] Draft work", "brackets in a title stay")
        let long = SessionTitles.clean(String(repeating: "word ", count: 60), limit: 20)
        check(long.count <= 21 && long.hasSuffix("\u{2026}"), long)
    }),
    ("session links: tool answers and running text fill in the titles as the transcript grows", {
        var links = SessionLinks()
        let items = [tool("t1", "ACME-12", result: "# ACME-12 Export the list\nStory \u{00B7} Done\n"),
                     AgentItem(id: "a1", kind: .text("Then ORB-4: Upgrade the parser carefully"))]
        check(links.update(items, projects: projects), "changed")
        check(links.titles[.jira("ACME-12")]?.title == "Export the list", "\(links.titles)")
        check(links.hints[.jira("ORB-4")] == "Upgrade the parser carefully", "\(links.hints)")
        let before = links
        check(!links.update(items, projects: projects) && links == before, "read once")
    }),
    ("session links: a later answer adds to what an earlier one said, a title found later does not replace the first", {
        var links = SessionLinks()
        links.update([tool("t1", "x", result: "- acme-com/orbit.api#7 Add the endpoint\n  https://github.com/acme-com/orbit.api/pull/7\n  by sam \u{00B7} now\n")], projects: projects)
        links.update([tool("t2", "x", result: "- acme-com/orbit.api#7 Add the endpoint\n  https://github.com/acme-com/orbit.api/pull/7\n  merged \u{00B7} by sam \u{00B7} now\n")], projects: projects)
        check(links.titles[pr(7)]?.state == "merged", "\(links.titles)")
    }),
    ("session ref: a row is complete when it has a title and a status or state, and settled when done, merged or closed", {
        check(SessionRefInfo(title: "T", status: "Done").isComplete(for: .jira("ACME-1")), "ticket with status")
        check(!SessionRefInfo(title: "T").isComplete(for: .jira("ACME-1")), "ticket without status")
        check(SessionRefInfo(title: "T", state: "open").isComplete(for: pr(1)), "pull request with state")
        check(!SessionRefInfo(title: "", state: "open").isComplete(for: pr(1)), "no title")
        check(SessionRefInfo(title: "T", category: "done").isSettled && SessionRefInfo(title: "T", state: "merged").isSettled, "settled")
        check(!SessionRefInfo(title: "T", status: "In Progress", state: "open").isSettled, "open")
        check(SessionRefInfo(title: "T", status: "Resolved").statusKind == .done && SessionRefInfo(title: "T", status: "In Review").statusKind == .inProgress, "names")
        check(SessionRefInfo(title: "T", status: "Odd", category: "new").statusKind == .todo, "category wins")
    }),
    ("session ref: a field comes from the most trusted source that has it", {
        let live = SessionRefInfo(title: "Live title", status: "Done", category: "done")
        let fetched = entry(SessionRefInfo(title: "Fetched title", status: "In Progress", category: "indeterminate"))
        let transcript = SessionRefInfo(title: "Transcript title", status: "To Do")
        let all = SessionRefLookup.resolve(live: live, fetched: fetched, transcript: transcript, hint: "Hint title")
        check(all?.title == "Live title" && all?.status == "Done", "\(String(describing: all))")
        let noLive = SessionRefLookup.resolve(live: nil, fetched: fetched, transcript: transcript, hint: "Hint title")
        check(noLive?.title == "Fetched title", "fetched")
        let onlyTranscript = SessionRefLookup.resolve(live: nil, fetched: nil, transcript: transcript, hint: "Hint title")
        check(onlyTranscript?.title == "Transcript title", "transcript")
        let hintOnly = SessionRefLookup.resolve(live: nil, fetched: entry(nil), transcript: nil, hint: "Hint title")
        check(hintOnly == SessionRefInfo(title: "Hint title"), "a lookup that found nothing leaves the hint")
        check(SessionRefLookup.resolve(live: nil, fetched: nil, transcript: nil, hint: nil) == nil, "nothing known")
        let partial = SessionRefLookup.resolve(live: SessionRefInfo(title: "", state: "merged"), fetched: nil, transcript: SessionRefInfo(title: "From a tool"), hint: nil)
        check(partial == SessionRefInfo(title: "From a tool", state: "merged"), "a field the live data lacks is kept")
    }),
    ("session ref lookup: only the refs that need it are asked for, a ticket batch and a pull request batch", {
        let refs: [SessionRef] = [.jira("ACME-1"), pr(2), .jira("ACME-3"), pr(4, repo: "acme-com/orbit.web")]
        let all = plan(refs)
        check(all.tickets == [["ACME-1", "ACME-3"]], "\(all.tickets)")
        check(all.pullRequests.count == 1 && all.pullRequests[0].map(\.number) == [2, 4], "\(all.pullRequests)")
        check(all.ids.count == 4, "ids")
        check(plan(refs, skip: Set(refs.map(\.cacheKey))).isEmpty, "all skipped")
        check(plan(refs, skip: [refs[0].cacheKey]).tickets == [["ACME-3"]], "one skipped")
    }),
    ("session ref lookup: the same ref in another case is asked for once, and a repeat in the list too", {
        let refs: [SessionRef] = [pr(2, repo: "Acme-Com/Orbit.Api"), pr(2), .jira("ACME-1"), .jira("ACME-1")]
        let all = plan(refs)
        check(all.pullRequests.flatMap { $0 }.count == 1 && all.tickets.flatMap { $0 }.count == 1, "\(all)")
    }),
    ("session ref lookup: a fresh answer, a failure that is backing off and a lookup under way are not asked for again", {
        let ticket = SessionRef.jira("ACME-1"), open = pr(2), missing = SessionRef.jira("ACME-9")
        let cache = [ticket.cacheKey: entry(SessionRefInfo(title: "T", status: "Done", category: "done"), age: 3600),
                     open.cacheKey: entry(SessionRefInfo(title: "P", state: "open"), age: 60),
                     missing.cacheKey: entry(nil, age: 600)]
        check(plan([ticket, open, missing], cache: cache).isEmpty, "all fresh")
        check(plan([ticket], backoff: [:], inFlight: [ticket.cacheKey]).isEmpty, "in flight")
        check(plan([ticket], backoff: [ticket.cacheKey: now.addingTimeInterval(60)]).isEmpty, "backing off")
        check(!plan([ticket], backoff: [ticket.cacheKey: now.addingTimeInterval(-1)]).isEmpty, "backoff over")
    }),
    ("session ref lookup: an open answer is kept for minutes, a settled one for hours, a missing one for an hour", {
        let open = entry(SessionRefInfo(title: "T", state: "open"), age: SessionRefLookup.openLifetime + 1)
        let settled = entry(SessionRefInfo(title: "T", state: "merged"), age: SessionRefLookup.openLifetime + 1)
        let old = entry(SessionRefInfo(title: "T", state: "merged"), age: SessionRefLookup.settledLifetime + 1)
        check(!SessionRefLookup.isFresh(open, now: now) && SessionRefLookup.isFresh(settled, now: now) && !SessionRefLookup.isFresh(old, now: now), "lifetimes")
        check(SessionRefLookup.isFresh(entry(nil, age: SessionRefLookup.missingLifetime - 1), now: now), "missing kept")
        check(!SessionRefLookup.isFresh(entry(nil, age: SessionRefLookup.missingLifetime + 1), now: now), "missing expires")
        check(!plan([pr(2)], cache: [pr(2).cacheKey: open]).isEmpty, "an expired open answer is asked again")
    }),
    ("session ref lookup: many refs are split into batches", {
        let tickets = (1...(SessionRefLookup.ticketBatch + 5)).map { SessionRef.jira("ACME-\($0)") }
        let prs = (1...(SessionRefLookup.pullRequestBatch + 2)).map { pr($0) }
        let all = plan(tickets + prs)
        check(all.tickets.map(\.count) == [SessionRefLookup.ticketBatch, 5], "\(all.tickets.map(\.count))")
        check(all.pullRequests.map(\.count) == [SessionRefLookup.pullRequestBatch, 2], "\(all.pullRequests.map(\.count))")
    }),
    ("session ref lookup: the search only holds valid keys", {
        check(SessionRefLookup.jql(["ACME-1", "ORB-22"]) == #"key in ("ACME-1", "ORB-22")"#, SessionRefLookup.jql(["ACME-1", "ORB-22"]))
        check(SessionRefLookup.jql(["ACME-1\") OR (1=1", "x y"]) == "key in ()", "bad keys dropped")
    }),
    ("session ref lookup: a ticket the search did not return is remembered as missing, one it returned as found", {
        let found = [JiraTicket(key: "ACME-1", summary: "One", status: "Done", priority: nil, updated: nil, category: .done)]
        let entries = SessionRefLookup.entries(forTickets: ["ACME-1", "ACME-2"], found: found, now: now)
        check(entries[SessionRef.jira("ACME-1").cacheKey]?.info == SessionRefInfo(title: "One", status: "Done", category: "done"), "found")
        check(entries[SessionRef.jira("ACME-2").cacheKey]?.info == nil && entries[SessionRef.jira("ACME-2").cacheKey]?.fetched == now, "missing")
    }),
    ("session ref lookup: pull requests are matched by address in any case", {
        let found = [GitHubPR(url: "https://github.com/acme-com/orbit.api/pull/7", number: 7, title: "Seven", repo: "acme-com/orbit.api", isDraft: true,
                              state: .open, updated: now, checks: .failed)]
        let targets = [GitHubLink.Target(repo: "Acme-Com/Orbit.Api", number: 7), GitHubLink.Target(repo: "acme-com/orbit.api", number: 8)]
        let entries = SessionRefLookup.entries(forPullRequests: targets, found: found, now: now)
        check(entries[pr(7).cacheKey]?.info == SessionRefInfo(title: "Seven", state: "open", isDraft: true, checks: "failed"), "\(entries)")
        check(entries[pr(8).cacheKey] != nil && entries[pr(8).cacheKey]?.info == nil, "missing")
    }),
    ("session ref lookup: a failure waits longer when nothing is set up", {
        check(SessionRefLookup.retryAfter(unconfigured: false, now: now) == now.addingTimeInterval(SessionRefLookup.failureBackoff), "failure")
        check(SessionRefLookup.retryAfter(unconfigured: true, now: now) == now.addingTimeInterval(SessionRefLookup.unconfiguredBackoff), "not set up")
    }),
    ("session ref lookup: the cache survives a restart, keeps the newest answers and ignores a broken file", {
        var cache: [String: SessionRefEntry] = [:]
        for index in 0..<(SessionRefLookup.cacheLimit + 10) { cache["acme-\(index)"] = entry(SessionRefInfo(title: "T\(index)"), age: TimeInterval(index)) }
        let restored = SessionRefLookup.decode(SessionRefLookup.encode(cache))
        check(restored.count == SessionRefLookup.cacheLimit, "\(restored.count)")
        check(restored["acme-0"] != nil && restored["acme-\(SessionRefLookup.cacheLimit + 9)"] == nil, "newest kept")
        check(restored["acme-0"]?.fetched == now, "date kept")
        check(SessionRefLookup.decode(Data("nope".utf8)).isEmpty && SessionRefLookup.decode(nil).isEmpty, "broken")
    }),
    ("session ref: the status mark of a looked-up pull request is the GitHub page's", {
        let info = SessionRefInfo(title: "Seven", state: "merged", isDraft: true, checks: "passed")
        let made = info.pullRequest(for: GitHubLink.Target(repo: "acme-com/orbit.api", number: 7), updated: now)
        check(made.state == .merged && made.isDraft && made.checks == .passed && made.title == "Seven" && made.number == 7, "\(made)")
        check(SessionRefInfo(title: "x").pullRequest(for: GitHubLink.Target(repo: "a/b", number: 1), updated: now).state == .open, "open by default")
    }),
]
