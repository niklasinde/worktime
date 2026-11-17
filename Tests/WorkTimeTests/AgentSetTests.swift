import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func url(_ number: Int, repo: String = "acme-com/orbit.api") -> String { "https://github.com/\(repo)/pull/\(number)" }

private func linked(_ numbers: [Int], repo: String = "acme-com/orbit.api") -> [LinkedPR] {
    numbers.map { LinkedPR(url: url($0, repo: repo), repo: repo, number: $0) }
}

private func set(_ id: String, _ prs: [LinkedPR], archived: Bool = false) -> TopicAgent {
    var topic = TopicAgent(id: id, name: PullRequestSets.name(prs), folder: "/tmp/\(id)", created: now, pullRequests: prs)
    topic.archived = archived
    return topic
}

private func ticket(_ prs: [LinkedPR]) -> TopicAgent {
    TopicAgent(id: "T1", name: "ACME-1 \u{00B7} Export", jiraKey: "ACME-1", folder: "/tmp/t1", created: now, pullRequests: prs)
}

private let id1 = "11111111-1111-1111-1111-111111111111"
private let id2 = "22222222-2222-2222-2222-222222222222"

let agentSetTests: [(name: String, run: () throws -> Void)] = [
    ("set: pull request urls are parsed once each, in order, and a bad one or too many is refused", {
        guard case .success(let found) = PullRequestSets.linked([url(2), url(1), url(2) + " "]) else { return check(false, "parsed") }
        check(found.map(\.number) == [2, 1], "\(found)")
        check(found[0].label == "acme-com/orbit.api#2" && found[0].shortLabel == "orbit.api#2", found[0].label)
        check(PullRequestSets.linked([url(1), "https://example.com/x"]) == .failure(.notPullRequest("https://example.com/x")), "not a pull request")
        let many = (1...11).map { url($0) }
        check(PullRequestSets.linked(many) == .failure(.tooMany(11)), "limit")
    }),
    ("set: adding keeps known ones in place and fills in what they lacked, removing takes one out", {
        var known = linked([1, 2])
        known[0].title = "First"
        var incoming = linked([1, 3])
        incoming[0].title = "Ignored"
        incoming[0].checkout = "/repos/orbit.api"
        let merged = PullRequestSets.adding(incoming, to: known)
        check(merged.map(\.number) == [1, 2, 3], "order \(merged.map(\.number))")
        check(merged[0].title == "First" && merged[0].checkout == "/repos/orbit.api", "kept the title, took the checkout")
        check(PullRequestSets.removing(url(2), from: merged).map(\.number) == [1, 3], "removed")
        check(PullRequestSets.removing(url(9), from: merged) == merged, "unknown")
    }),
    ("set: a pull request routes to the set that holds it, an archived set last, and stays its own url otherwise", {
        let one = set(id1, linked([1, 2])), archived = set(id2, linked([2, 3]), archived: true)
        let topics = [archived, one]
        check(PullRequestSets.route(url(1), in: topics) == one.key, "in a set")
        check(PullRequestSets.route(url(2), in: topics) == one.key, "the live set wins over the archived one")
        check(PullRequestSets.route(url(3), in: topics) == archived.key, "only an archived set holds it")
        check(PullRequestSets.route(url(9), in: topics) == url(9), "not in a set")
        check(PullRequestSets.set(coveringAll: [url(1), url(2)], in: topics)?.id == id1, "covers both")
        check(PullRequestSets.set(coveringAll: [url(1), url(3)], in: topics) == nil, "covers only one")
    }),
    ("set: a pull request is in one set only, and the key of a set does not change when its pull requests do", {
        let first = set(id1, linked([1, 2])), second = set(id2, linked([3]))
        let moved = PullRequestSets.assigning([url(2), url(4)], to: second.key, in: [first, second])
        check(moved[0].linked.map(\.number) == [1], "left the first set")
        check(moved[1] == second, "the target is untouched here")
        check(moved.map(\.key) == [first.key, second.key], "keys are stable")
        check(first.key == "topic:" + id1 && TopicAgents.isKey(first.key), first.key)
    }),
    ("set: it is named after its first pull requests and works in the checkout they share, else in a folder of its own", {
        check(PullRequestSets.name(linked([1])) == "Review: orbit.api#1", PullRequestSets.name(linked([1])))
        check(PullRequestSets.name(linked([1, 2, 3, 4])) == "Review: orbit.api#1, orbit.api#2 +2", PullRequestSets.name(linked([1, 2, 3, 4])))
        var shared = linked([1, 2])
        for index in shared.indices { shared[index].checkout = "/repos/orbit.api" }
        check(PullRequestSets.workingFolder(shared, own: "/own") == "/repos/orbit.api", "shared checkout")
        shared[1].checkout = nil
        check(PullRequestSets.workingFolder(shared, own: "/own") == "/own", "one has none")
        var mixed = linked([1]) + linked([5], repo: "acme-com/orbit.ui")
        mixed[0].checkout = "/repos/orbit.api"
        mixed[1].checkout = "/repos/orbit.ui"
        check(PullRequestSets.workingFolder(mixed, own: "/own") == "/own", "two repositories")
    }),
    ("set: the set kind, its prompts name every pull request and never allow posting, a ticket topic gets them as a section", {
        var prs = linked([1, 2])
        prs[0].title = "Add the export"
        prs[1].checkout = "/repos/orbit.api"
        let topic = set(id1, prs)
        check(topic.kind == .pullRequests && ticket(prs).kind == .ticket && TopicAgent(id: "x", name: "n", folder: "/f", created: now).kind == .topic, "kinds")
        let system = TopicAgents.systemPrompt(topic)
        check(system.contains(url(1)) && system.contains(url(2)) && system.contains("Add the export") && system.contains("/repos/orbit.api"), system)
        check(system.contains("never post, approve, merge or comment"), "draft only")
        check(TopicAgents.prompt(topic).contains("one change") && TopicAgents.prompt(topic).contains(url(2)), TopicAgents.prompt(topic))
        let mixed = TopicAgents.systemPrompt(ticket(prs))
        check(mixed.contains("ACME-1") && mixed.contains("Pull requests linked to this topic") && mixed.contains(url(1)), mixed)
        check(!TopicAgents.systemPrompt(TopicAgent(id: "x", name: "n", folder: "/f", created: now)).contains("Pull requests linked"), "plain topic")
    }),
    ("set: send_to_agent for a pull request in a set reaches the set, and an archived set is not used", {
        let one = set(id1, linked([1, 2]))
        check(TopicAgents.resolve(url(2), topics: [one]) == .success(AgentTarget(key: one.key, title: one.name)), "routed")
        check(TopicAgents.resolve(url(9), topics: [one]) == .success(AgentTarget(key: url(9), title: AgentOverview.prTitle(url(9)))), "own agent")
        var archived = one
        archived.archived = true
        check(TopicAgents.resolve(url(2), topics: [archived]) == .success(AgentTarget(key: url(2), title: AgentOverview.prTitle(url(2)))), "archived")
    }),
    ("set: topics saved before sets existed still read, and a set round-trips", {
        let old = Data(#"[{"id":"A","name":"Support","folder":"/f","created":"2027-01-15T08:00:00Z","archived":false}]"#.utf8)
        let topics = TopicAgents.decode(old)
        check(topics.count == 1 && topics[0].linked.isEmpty && topics[0].kind == .topic, "old file")
        let saved = [set(id1, linked([1, 2]))]
        check(TopicAgents.decode(TopicAgents.encode(saved)) == saved, "round trip")
    }),
    ("set: a prompt for several pull requests needs two or more good ones, and an old request still reads", {
        let ok = AgentInbox.request(agent: url(1), text: "Review", now: now, id: id1, prs: [url(1), url(2)])
        guard case .success(let request) = ok else { return check(false, "\(ok)") }
        check(request.prs == [url(1), url(2)], "kept")
        check(AgentInbox.decode(AgentInbox.Request.self, from: AgentInbox.encode(request)) == request, "round trip")
        let one = AgentInbox.request(agent: url(1), text: "Review", now: now, id: id1, prs: [url(1)])
        check(one == .failure(AgentInboxError(AgentSetError.needTwo.message)), "\(one)")
        let bad = AgentInbox.request(agent: url(1), text: "Review", now: now, id: id1, prs: [url(1), "https://example.com"])
        check(bad == .failure(AgentInboxError(AgentSetError.notPullRequest("https://example.com").message)), "\(bad)")
        let old = Data(#"{"id":"\#(id1)","agent":"\#(url(1))","text":"Hi","created":"2027-01-15T08:00:00Z"}"#.utf8)
        check(AgentInbox.decode(AgentInbox.Request.self, from: old)?.prs == nil, "no prs")
    }),
    ("set: the overview names the set and lists its pull requests", {
        let topic = set(id1, linked([1, 2]))
        let state = AgentState.topic(topic, loaded: nil, sessionID: nil)
        check(state.pullRequests == [url(1), url(2)], "\(String(describing: state.pullRequests))")
        let text = AgentOverview.markdown(.init(written: now, agents: [state]), now: now, active: false)
        check(text.contains("pull request set agent \(topic.key)") && text.contains(url(2)), text)
        check(AgentState.topic(TopicAgent(id: "x", name: "n", folder: "/f", created: now), loaded: nil, sessionID: nil).pullRequests == nil, "plain topic")
    }),
    ("set: a Slack message with several pull requests makes one event for a set, and the question hands them to one agent", {
        let text = "Please review \(url(1)) and \(url(2)) and acme-com/orbit.api#3 together"
        check(PullRequestSets.urls(in: text) == [url(1), url(2), url(3)], "\(String(describing: PullRequestSets.urls(in: text)))")
        check(PullRequestSets.urls(in: "just \(url(1))") == nil, "one is not a set")
        let slack = SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: "#reviews", author: "Anna", text: text, ts: "1800000000.000100",
                                 permalink: "https://acme.slack.com/archives/C1/p1800000000000100")
        let event = Automations.slackEvent(slack, link: nil)
        check(event.pullRequests?.count == 3 && event.fields["pr_urls"] == [url(1), url(2), url(3)].joined(separator: "\n") && event.pullRequest == url(1), "\(event)")
        check(Automations.prompt("Review {pr_urls}", event: event).contains(url(3)), "placeholder")
        let ask = AutomationAsk(yes: "Review it", no: "Skip")
        let routine = Routine(id: "A1", name: "Reviews", prompt: "triage", workspace: "work", schedule: RoutineSchedule(kind: .daily), created: now,
                              trigger: AutomationTrigger(kind: .slackMessage), followUp: AutomationFollowUp(notify: true, remind: true, ask: ask))
        let run = RoutineRun(started: now, finished: now, status: .done, summary: "Recommendation: review")
        let notice = AutomationAsks.notice(for: routine, event: event, run: run, ask: ask, reminder: nil)
        check(notice?.pullRequests?.count == 3 && notice?.agent == url(1) && notice?.prompt.contains(url(2)) == true, "\(String(describing: notice))")
        var named = ask
        named.agent = "assistant:work:reviewer"
        let toAssistant = AutomationAsks.notice(for: routine, event: event, run: run, ask: named, reminder: nil)
        check(toAssistant?.pullRequests == nil && toAssistant?.agent == "assistant:work:reviewer", "an assistant gets the prompt, not a set")
    }),
]
