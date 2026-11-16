import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fakeToken = "FAKE-JIRA-TOKEN-0000"

private func issue(_ key: String, summary: String = "Fix the thing", status: String = "In Progress", priority: String? = "High",
                   updated: String = "2026-10-19T12:58:21.000+0200") -> String {
    let priorityJSON = priority.map { #"{"name":"\#($0)"}"# } ?? "null"
    return #"{"id":"1","key":"\#(key)","fields":{"summary":"\#(summary)","status":{"name":"\#(status)","statusCategory":{"key":"indeterminate"}},"priority":\#(priorityJSON),"updated":"\#(updated)"}}"#
}

private func searchResponse(_ issues: [String], tail: String = #""isLast":true"#) -> Data {
    Data(#"{"issues":[\#(issues.joined(separator: ","))],\#(tail)}"#.utf8)
}

private final class Requests: @unchecked Sendable {
    var seen: [URLRequest] = []
}

/// A transport answering each path with a fixed status and body, recording the requests.
private func fake(_ answers: [String: (Int, Data)], requests: Requests = Requests()) -> JiraTransport {
    { request in
        requests.seen.append(request)
        let (status, body) = answers[request.url?.path ?? ""] ?? (404, Data())
        return (body, status)
    }
}

private final class Outcome<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = Outcome<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

private func client(_ transport: @escaping JiraTransport) -> JiraClient {
    JiraClient(site: "acme.atlassian.net", email: "me@acme.com", token: fakeToken, transport: transport)
}

let jiraTests: [(name: String, run: () throws -> Void)] = [
    ("a search/jql response is parsed into tickets with every field", {
        let search = try JiraLogic.parseSearch(searchResponse([issue("QDLY-1"), issue("QDLY-2", summary: "Other", status: "To Do", priority: nil)]))
        check(search.tickets.map(\.key) == ["QDLY-1", "QDLY-2"], "keys")
        check(search.tickets[0].summary == "Fix the thing" && search.tickets[0].status == "In Progress", "summary and status")
        check(search.tickets[0].priority == "High" && search.tickets[1].priority == nil, "priority")
        check(search.tickets[0].updated == Date(timeIntervalSince1970: 1_792_407_501), "updated \(String(describing: search.tickets[0].updated))")
        check(search.total == 2, "the last page counts itself")
    }),

    ("the total comes from the legacy response, and is unknown when more pages follow", {
        check(try JiraLogic.parseSearch(searchResponse([issue("A-1")], tail: #""total":57,"startAt":0"#)).total == 57, "legacy total")
        check(try JiraLogic.parseSearch(searchResponse([issue("A-1")], tail: #""isLast":false,"nextPageToken":"abc""#)).total == nil, "more pages")
        check(JiraLogic.headline(total: 57, shown: 20) == "57 assigned to you", "known total")
        check(JiraLogic.headline(total: nil, shown: 20) == "20+ assigned to you", "unknown total")
    }),

    ("the JQL asks for open tickets assigned to the user, newest first", {
        check(JiraLogic.jql == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", "jql")
        let body = JiraLogic.searchBody
        check(body["jql"] as? String == JiraLogic.jql, "body jql")
        check(body["fields"] as? [String] == ["key", "summary", "status", "priority", "updated"], "fields")
        check(body["maxResults"] as? Int == 20, "max results")
    }),

    ("requests go to the site over https with Basic auth and a JSON body", {
        let request = JiraLogic.request(site: "acme.atlassian.net", path: JiraLogic.searchPath, email: "me@acme.com", token: fakeToken,
                                        body: JiraLogic.searchBody)
        check(request.url?.absoluteString == "https://acme.atlassian.net/rest/api/3/search/jql", "url \(request.url?.absoluteString ?? "")")
        check(request.httpMethod == "POST", "post")
        let expected = "Basic " + Data("me@acme.com:\(fakeToken)".utf8).base64EncodedString()
        check(request.value(forHTTPHeaderField: "Authorization") == expected, "basic auth")
        let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        check(sent?["jql"] as? String == JiraLogic.jql && sent?["maxResults"] as? Int == 20, "body")
        let myself = JiraLogic.request(site: "acme.atlassian.net", path: JiraLogic.myselfPath, email: "me@acme.com", token: fakeToken)
        check(myself.httpMethod == "GET" && myself.httpBody == nil, "myself is a GET")
    }),

    ("a typed site is reduced to its host, and the browse link is built from it", {
        check(JiraLogic.site("https://Acme.atlassian.net/browse/QDLY-1") == "acme.atlassian.net", "pasted link")
        check(JiraLogic.site(" acme.atlassian.net/ ") == "acme.atlassian.net", "trailing slash")
        check(JiraLogic.site("acme") == "acme.atlassian.net", "bare name")
        check(JiraLogic.site("") == nil && JiraLogic.site("not a site") == nil, "rejected")
        check(JiraLogic.browseURL(site: "acme.atlassian.net", key: "QDLY-8")?.absoluteString == "https://acme.atlassian.net/browse/QDLY-8", "browse")
    }),

    ("the suggested site is the one most prefixes point at", {
        check(JiraLogic.suggestedSite([:]) == nil, "none known")
        check(JiraLogic.suggestedSite(["QDLY": "b.atlassian.net", "QPB": "b.atlassian.net", "X": "a.atlassian.net"]) == "b.atlassian.net", "most")
        check(JiraLogic.suggestedSite(["X": "b.atlassian.net", "Y": "a.atlassian.net"]) == "a.atlassian.net", "tie by name")
    }),

    ("the client searches the current endpoint and counts beyond the first page", {
        let requests = Requests()
        let transport = fake([JiraLogic.searchPath: (200, searchResponse([issue("A-1")], tail: #""isLast":false,"nextPageToken":"x""#)),
                              JiraLogic.countPath: (200, Data(#"{"count":42}"#.utf8))], requests: requests)
        let search = try blocking { try await client(transport).assigned() }.get()
        check(search.tickets.map(\.key) == ["A-1"] && search.total == 42, "tickets and count")
        check(requests.seen.map { $0.url?.path ?? "" } == [JiraLogic.searchPath, JiraLogic.countPath], "paths")
        let count = try JSONSerialization.jsonObject(with: requests.seen[1].httpBody ?? Data()) as? [String: Any]
        check(count?["jql"] as? String == JiraLogic.filter, "count without ordering")
    }),

    ("the client falls back to the older search endpoint when the current one is missing", {
        let requests = Requests()
        let transport = fake([JiraLogic.legacySearchPath: (200, searchResponse([issue("A-1"), issue("A-2")], tail: #""total":2"#))],
                             requests: requests)
        let search = try blocking { try await client(transport).assigned() }.get()
        check(search.tickets.count == 2 && search.total == 2, "legacy result")
        check(requests.seen.map { $0.url?.path ?? "" } == [JiraLogic.searchPath, JiraLogic.legacySearchPath], "fell back")
    }),

    ("errors are classified, and none of them contains the token", {
        let unauthorized = blocking { try await client(fake([JiraLogic.myselfPath: (401, Data())])).displayName() }
        check((try? unauthorized.get()) == nil, "401 fails")
        if case .failure(let error) = unauthorized { check(error as? JiraError == .unauthorized, "unauthorized \(error)") }
        let body = Data(#"{"errorMessages":["The value 'x' does not exist for the field 'project'."],"errors":{}}"#.utf8)
        check(JiraError.from(status: 400, body: body) == .failed("The value 'x' does not exist for the field 'project'."), "error message")
        check(JiraError.from(status: 500, body: Data()) == .failed("HTTP 500"), "bare status")
        check(JiraError.from(URLError(.cannotFindHost)) == .offline, "offline")
        let name = blocking { try await client(fake([JiraLogic.myselfPath: (200, Data(#"{"displayName":"Niklas Inde"}"#.utf8))])).displayName() }
        check((try? name.get()) == "Niklas Inde", "display name")
        for error in [JiraError.unauthorized, .forbidden, .notFound, .offline, .rateLimited, .notConfigured] {
            check(!error.message.contains(fakeToken), "no token in \(error)")
        }
    }),

    ("the token store saves a trimmed token and removes it, with an in-memory store", {
        let secrets = MemorySecretStore()
        let tokens = TokenStore(secrets: secrets, account: TokenStore.jira.account)
        check(tokens.token() == nil, "nothing saved yet")
        try tokens.save("  \(fakeToken)\n")
        check(tokens.token() == fakeToken, "trimmed token")
        check(secrets.key(for: TokenStore.jira.account) == Data(fakeToken.utf8), "stored under the api-token account")
        tokens.remove()
        check(tokens.token() == nil, "removed")
    }),

    ("the Jira page asks for the unresolved tickets assigned to me, the ones I reported and the ones I watch", {
        check(JiraTab.allCases.map(\.title) == ["Assigned", "Reported", "Watching"], "tabs")
        check(JiraTab.assigned.jql == "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", JiraTab.assigned.jql)
        check(JiraTab.reported.jql == "reporter = currentUser() ORDER BY updated DESC", JiraTab.reported.jql)
        check(JiraTab.watching.jql == "watcher = currentUser() ORDER BY updated DESC", JiraTab.watching.jql)
        check(JiraLogic.listFields.contains("issuetype") && JiraLogic.listFields.contains("assignee") && JiraLogic.listFields.contains("status"), "fields")
    }),

    ("search results carry the type, assignee, labels and status category the rows need", {
        let json = #"{"issues":[{"key":"QDLY-9","fields":{"summary":"S","status":{"name":"Review","statusCategory":{"key":"indeterminate"}},"priority":{"name":"High"},"updated":"2026-10-19T12:58:21.000+0200","issuetype":{"name":"Bug"},"assignee":{"displayName":"Niklas Inde"},"labels":["blocked"]}}],"isLast":true}"#
        let ticket = try JiraLogic.parseSearch(Data(json.utf8)).tickets[0]
        check(ticket.type == "Bug" && ticket.assignee == "Niklas Inde" && ticket.labels == ["blocked"] && ticket.category == .inProgress, "\(ticket)")
        let bare = try JiraLogic.parseSearch(searchResponse([issue("A-1")])).tickets[0]
        check(bare.type == nil && bare.assignee == nil && bare.labels.isEmpty, "optional fields")
    }),

    ("a ticket's stage follows its status category, and review comes from the status name", {
        func stage(_ status: String, _ category: JiraStatusCategory?) -> JiraStage {
            JiraTickets.stage(JiraTicket(key: "A-1", summary: "", status: status, priority: nil, updated: nil, category: category))
        }
        check(stage("Backlog", .todo) == .todo && stage("In Progress", .inProgress) == .inProgress, "todo and progress")
        check(stage("Review", .inProgress) == .inReview && stage("In Verification", .inProgress) == .inReview, "review")
        check(stage("Released", .done) == .done, "done")
        check(stage("To Do", nil) == .todo && stage("Closed", nil) == .done && stage("Code review", nil) == .inReview && stage("Doing", nil) == .inProgress, "no category")
        check(JiraStage.allCases.map(\.title) == ["To do", "In progress", "In review", "Done"], "titles")
    }),

    ("the chips: my turn is mine and not done, in review or blocked; blocked, in review and recently done", {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func ticket(_ key: String, _ status: String, _ category: JiraStatusCategory, age: Double = 0, labels: [String] = []) -> JiraTicket {
            JiraTicket(key: key, summary: "S \(key)", status: status, priority: nil, updated: now.addingTimeInterval(-age * 86_400),
                       category: category, labels: labels)
        }
        let tickets = [ticket("A-1", "In Progress", .inProgress), ticket("A-2", "Review", .inProgress), ticket("A-3", "Blocked", .inProgress),
                       ticket("A-4", "To Do", .todo, labels: ["Blocked-by-vendor"]), ticket("A-5", "Done", .done, age: 2),
                       ticket("A-6", "Done", .done, age: 30), ticket("B-1", "To Do", .todo)]
        let mine: Set<String> = ["A-1", "A-2", "A-3", "A-4", "A-5", "A-6"]
        func keys(_ tab: JiraStatusTab) -> [String] {
            JiraTickets.filter(tickets, JiraFilter(status: tab), mine: mine, now: now).map(\.key)
        }
        check(keys(.all).count == 7, "all")
        check(keys(.myTurn) == ["A-1"], "my turn \(keys(.myTurn))")
        check(keys(.inReview) == ["A-2"], "in review")
        check(keys(.blocked) == ["A-3", "A-4"], "blocked by status or label")
        check(keys(.done) == ["A-5"], "done recently")
        let counts = JiraTickets.counts(tickets, JiraFilter(), mine: mine, now: now)
        check(counts[.all] == 7 && counts[.myTurn] == 1 && counts[.blocked] == 2 && counts[.done] == 1, "\(counts)")
        check(JiraStatusTab.allCases.map(\.title) == ["All", "My turn", "In review", "Blocked", "Done recently"], "titles")
    }),

    ("the page filters match like jira_search: project, type, status, priority and assignee, several by comma", {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        func ticket(_ key: String, type: String, status: String, priority: String?, assignee: String?, summary: String = "Export") -> JiraTicket {
            JiraTicket(key: key, summary: summary, status: status, priority: priority, updated: now, type: type, assignee: assignee, category: .inProgress)
        }
        let tickets = [ticket("QDLY-1", type: "Bug", status: "Review", priority: "High", assignee: "Niklas Inde"),
                       ticket("ISD-2", type: "Support", status: "Waiting", priority: nil, assignee: nil, summary: "Login fails"),
                       ticket("QDLY-3", type: "Task", status: "To Do", priority: "Low", assignee: "Anna Berg")]
        func keys(_ filter: JiraFilter) -> [String] { JiraTickets.filter(tickets, filter, mine: [], now: now).map(\.key) }
        check(keys(JiraFilter(project: "qdly")) == ["QDLY-1", "QDLY-3"] && keys(JiraFilter(project: "isd, qdly")).count == 3, "project")
        check(keys(JiraFilter(type: "bug,task")) == ["QDLY-1", "QDLY-3"] && keys(JiraFilter(statusName: "review")) == ["QDLY-1"], "type and status")
        check(keys(JiraFilter(priority: "Low")) == ["QDLY-3"] && keys(JiraFilter(assignee: "unassigned")) == ["ISD-2"], "priority and unassigned")
        check(keys(JiraFilter(assignee: "anna berg")) == ["QDLY-3"], "assignee")
        check(keys(JiraFilter(query: "login")) == ["ISD-2"] && keys(JiraFilter(query: "qdly-3 export")) == ["QDLY-3"], "search over key and summary")
        check(keys(JiraFilter(project: "qdly", type: "Bug")) == ["QDLY-1"], "combined")
        var filter = JiraFilter(status: .inReview, query: "x", project: "QDLY", priority: "High")
        check(filter.refinements == 2 && filter.withoutRefinements == JiraFilter(status: .inReview, query: "x"), "refinements")
        filter.assignee = "me"
        check(filter.refinements == 3, "assignee counts")
        let options = JiraTickets.options(tickets)
        check(options == JiraTickets.Options(projects: ["ISD", "QDLY"], types: ["Bug", "Support", "Task"], statuses: ["Review", "To Do", "Waiting"],
                                             priorities: ["High", "Low"], assignees: ["Anna Berg", "Niklas Inde"]), "\(options)")
    }),

    ("the page's refinements compose into the tab's JQL through jira_search's filter, and open in the Jira navigator", {
        check(JiraTickets.jql(.assigned, JiraFilter(query: "x")) == JiraTab.assigned.jql, "no refinements, no change")
        let jql = JiraTickets.jql(.assigned, JiraFilter(project: "QDLY", type: "Bug,Task"))
        check(jql == "(assignee = currentUser() AND resolution = Unresolved) AND project = \"QDLY\" AND issuetype in (\"Bug\", \"Task\") ORDER BY updated DESC", jql)
        let url = JiraTickets.navigatorURL(site: "acme.atlassian.net", jql: "project = \"A B\"")
        check(url?.absoluteString == "https://acme.atlassian.net/issues/?jql=project%20%3D%20%22A%20B%22", "\(String(describing: url))")
        check(JQLFilter.list(" a, b ,,c") == ["a", "b", "c"] && JQLFilter.list(nil).isEmpty, "list")
    }),

    ("a ticket key is typed in any case or pasted as a browse, board or selected-issue link", {
        check(JiraLogic.issueKey("qdly-8332") == "QDLY-8332", "lower case")
        check(JiraLogic.issueKey("https://kvidly.atlassian.net/browse/QDLY-8332") == "QDLY-8332", "browse")
        check(JiraLogic.issueKey("https://kvidly.atlassian.net/jira/software/projects/QDLY/boards/1?selectedIssue=QDLY-8332") == "QDLY-8332", "board")
        check(JiraLogic.issueKey("  ISD-1\n") == "ISD-1" && JiraLogic.issueKey("QDLY") == nil && JiraLogic.issueKey("hello world") == nil, "trimmed, refused")
        check(JiraTickets.project(of: "QDLY-8332") == "QDLY", "project of a key")
    }),

    ("pull requests are linked to tickets by the key in their title or head branch, open ones first", {
        func pr(_ number: Int, _ title: String, state: GitHubPR.State = .open) -> GitHubPR {
            GitHubPR(url: "https://github.com/acme/api/pull/\(number)", number: number, title: title, repo: "acme/api", state: state,
                     updated: Date(timeIntervalSince1970: 1_793_000_000 + Double(number)))
        }
        let prs = [pr(1, "QDLY-8332: Release note", state: .merged), pr(2, "Fix the thing"), pr(3, "QDLY-8332 again"), pr(4, "No key")]
        let linked = JiraTickets.pullRequests(prs) { $0.number == 2 ? "NI/QDLY-8332-fix" : $0.number == 4 ? "main" : nil }
        check(linked["QDLY-8332"]?.map(\.number) == [3, 2, 1], "open first, newest first \(String(describing: linked["QDLY-8332"]?.map(\.number)))")
        check(linked.count == 1, "only keyed pull requests")
    }),

    ("the page's lists are fetched per tab, a failing tab leaves the others, and the cache round-trips", {
        let requests = Requests()
        let transport: JiraTransport = { request in
            requests.seen.append(request)
            let jql = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["jql"] as? String ?? ""
            if jql.contains("watcher") { return (Data(), 403) }
            return (searchResponse([issue(jql.contains("reporter") ? "R-1" : "A-1")]), 200)
        }
        let fetch = blocking { await JiraTickets.fetchAll(client: client(transport)) }
        guard case .success(let result) = fetch else { return check(false, "fetch failed") }
        check(result.lists[.assigned]?.map(\.key) == ["A-1"] && result.lists[.reported]?.map(\.key) == ["R-1"] && result.lists[.watching] == nil, "lists")
        check(result.error == .forbidden, "the first error is kept \(String(describing: result.error))")
        let sent = requests.seen.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
        check(sent.count == 3 && sent.allSatisfy { ($0["fields"] as? [String]) == JiraLogic.listFields && $0["maxResults"] as? Int == JiraTickets.pageSize }, "bodies")
        check(JiraTickets.mine(result.lists) == ["A-1"], "mine is the assigned tab")
        let cache = JiraTickets.Cache(fetched: Date(timeIntervalSince1970: 1_793_000_000), lists: result.lists)
        check(JiraTickets.decode(JiraTickets.encode(cache)) == cache, "cache round trip")
        check(JiraTickets.decode(nil) == nil && JiraTickets.decode(Data("nope".utf8)) == nil, "bad cache")
        check(JiraTickets.header(count: 3, tab: .reported, capped: true) == "3+ reported", "header")
    }),

    ("ticket agents are the topic agents with a Jira key: found by key, kind ticket, named with the key", {
        let now = Date(timeIntervalSince1970: 1_793_000_000), root = URL(fileURLWithPath: "/data/Agents")
        guard case .success(let topic) = TopicAgents.make(name: TopicAgents.name(ticket: "QDLY-8332", summary: "Release note for the export"), jira: "QDLY-8332",
                                                           slack: "", root: root, taken: [], folder: "/Users/me/git/api", now: now),
              case .success(var old) = TopicAgents.make(name: "Old", jira: "QDLY-1", slack: "", root: root, taken: [], now: now)
        else { return check(false, "fixture") }
        check(topic.name == "QDLY-8332 \u{00B7} Release note for the export" && topic.kind == .ticket, topic.name)
        check(topic.folder == "/Users/me/git/api", "the repository folder is kept")
        check(TopicAgents.existing(jiraKey: "QDLY-8332", in: [old, topic]) == topic, "one agent per ticket")
        let target = AgentTarget(key: topic.key, title: topic.name)
        check(TopicAgents.resolve("qdly-8332", topics: [old, topic]) == .success(target), "by key")
        check(TopicAgents.resolve("https://acme.atlassian.net/browse/QDLY-8332", topics: [topic]) == .success(target), "by link")
        old.archived = true
        check(TopicAgents.resolve("QDLY-1", topics: [old]) == .failure(.archived("Old")), "archived")
        check(TopicAgents.resolve("QDLY-77", topics: [topic]) == .failure(.unknown("QDLY-77")), "no agent for it")
        let state = AgentState.topic(topic, loaded: nil, sessionID: "s1")
        let other = AgentState(key: "https://github.com/acme/api/pull/7", title: "pr", status: .idle)
        check(JiraTickets.agents([state, other]) == ["QDLY-8332": state], "agents by ticket key")
        check(AgentFilter.kind(of: state) == "ticket", "kind")
    }),

    ("the ticket agent's first prompt carries the ticket and its pull requests, and its system prompt forbids writing to Jira", {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let issue = try JiraLogic.parseIssue(Data(#"{"key":"QDLY-8332","fields":{"summary":"Release note","status":{"name":"In Progress"},"description":"Write it.","comment":{"total":0,"comments":[]}}}"#.utf8))
        let pr = GitHubPR(url: "https://github.com/acme/api/pull/9", number: 9, title: "QDLY-8332: Note", repo: "acme/api", updated: now, checks: .passed)
        let context = JiraAgents.context(issue: issue, pullRequests: [pr], site: "acme.atlassian.net", now: now)
        check(context.contains("# QDLY-8332 Release note") && context.contains("Write it.") && context.contains("https://acme.atlassian.net/browse/QDLY-8332"), context)
        check(context.contains("- acme/api#9 QDLY-8332: Note (open, checks passed) https://github.com/acme/api/pull/9"), "pull request line")
        check(JiraAgents.context(issue: issue, pullRequests: [], site: nil, now: now).contains("No pull request names it yet."), "none linked")
        let system = JiraAgents.systemPrompt(ticket: "QDLY-8332", name: "n", folder: "/Users/me/git/api")
        check(system.contains("jira_issue") && system.contains("github_pr") && system.contains("/Users/me/git/api") && system.contains("must never claim"), system)
        let topic = TopicAgent(id: UUID().uuidString, name: "QDLY-8332 \u{00B7} Note", jiraKey: "QDLY-8332", folder: "/Users/me/git/api", created: now)
        check(TopicAgents.systemPrompt(topic) == system.replacingOccurrences(of: "\u{201C}n\u{201D}", with: "\u{201C}\(topic.name)\u{201D}"), "a ticket-only topic uses it")
        check(JiraAgents.ticket(issue).summary == "Release note" && JiraAgents.ticket(issue).status == "In Progress", "list entry from an issue")
    }),
]
