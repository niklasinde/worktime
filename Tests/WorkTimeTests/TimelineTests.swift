import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let pull = "https://github.com/acme-com/orbit.api/pull/12"

private func item(_ id: String, _ kind: AgentItem.Kind, at seconds: TimeInterval, call: String? = nil) -> AgentItem {
    var made = AgentItem(id: id, kind: kind)
    made.date = start.addingTimeInterval(seconds)
    made.call = call
    return made
}

private let reviewBlock = """
    Looks fine apart from one thing.

    ```worktime-review
    {"pr": "\(pull)", "sha": "abcdef1234567", "verdict": "request_changes", "summary": "[AI] Fix the migration head.", "comments": []}
    ```
    """

private func scan(_ items: [AgentItem], session: String = "topic:1", label: String = "Reviewer") -> [TimelineEvent] {
    var scanner = TimelineScanner(session: session, label: label)
    scanner.update(items)
    return scanner.events
}

let timelineTests: [(name: String, run: () throws -> Void)] = [
    ("timeline: what Main asked, and what started it, are events of the session", {
        let events = scan([
            item("user-0", .user(AgentInbox.prompt("Review it", origin: "Slack channel message in #review-request")), at: 0),
            item("user-5", .user(AgentInbox.prompt("Look again")), at: 600),
        ])
        check(events.map(\.kind) == [.trigger, .prompt, .prompt], "\(events.map(\.kind))")
        check(events[0].title == "Triggered by Slack channel message in #review-request" && events[0].item == "user-0", events[0].title)
        check(events[1].title == "Main asked: Review it" && events[1].date == start, events[1].title)
        check(events[2].title == "Main asked: Look again" && events[2].date == start.addingTimeInterval(600), events[2].title)
        check(events.allSatisfy { $0.session == "topic:1" && $0.sessionLabel == "Reviewer" }, "session")
        check(Set(events.map(\.id)).count == 3, "each event has its own id")
    }),
    ("timeline: the origin travels in the prompt and the prompt still reads as from Main", {
        let prompt = AgentInbox.prompt("Verify ACME-1", origin: "Jira assigned in ACME")
        check(prompt == "From Main (Jira assigned in ACME): Verify ACME-1", prompt)
        check(AgentInbox.fromMain(prompt) == "Verify ACME-1" && AgentInbox.origin(of: prompt) == "Jira assigned in ACME", "parsed")
        check(AgentInbox.prompt("x") == "From Main: x" && AgentInbox.origin(of: "From Main: x") == nil && AgentInbox.fromMain("From Main: x") == "x", "no origin")
        check(AgentInbox.prompt("x", origin: "  A\n(b) c  ") == "From Main (A [b] c): x", "cleaned: \(AgentInbox.prompt("x", origin: "  A\n(b) c  "))")
        check(AgentInbox.fromMain("From Main (broken: x") == nil && AgentInbox.fromMain("hello") == nil, "not a prompt from Main")
        check(AgentInbox.cleaned(String(repeating: "a", count: 200))?.count == AgentInbox.originLimit, "limited")
        check(AgentInbox.cleaned("   ") == nil && AgentInbox.cleaned(nil) == nil, "empty")
    }),
    ("timeline: verdicts, drafted reviews and offered steps are outcomes of the reply", {
        let events = scan([
            item("user-0", .user(AgentInbox.prompt("Verify")), at: 0),
            item("text-1", .text("**ACME-1: BLOCKED.** No acceptance criteria to read."), at: 60),
            item("user-2", .user("Try again with Chrome"), at: 120),
            item("text-3", .text(reviewBlock), at: 180),
            item("text-4", .text("```worktime-action\ntitle: Check the migration\nassistant: Developer\nprompt: |\n  Fix it\n```"), at: 240),
            item("text-5", .text("Recommendation: review \u{2014} touches money"), at: 300),
        ])
        let kinds = events.map(\.kind)
        guard kinds == [.prompt, .outcome, .feedback, .review, .offer, .outcome] else { return check(false, "\(events.map { "\($0.kind): \($0.title)" })") }
        check(events[1].title == "BLOCKED: ACME-1: BLOCKED. No acceptance criteria to read.", events[1].title)
        check(events[2].title == "You: Try again with Chrome", events[2].title)
        check(events[3].title == "Review draft \u{00B7} orbit.api#12 \u{00B7} Request changes" && events[3].detail == "[AI] Fix the migration head.", "\(events[3].title) \(String(describing: events[3].detail))")
        check(events[4].title == "Offered: Check the migration", events[4].title)
        check(events[5].title == "Recommendation: review \u{2014} touches money", events[5].title)
    }),
    ("timeline: a reply that ends the turn is an event, one in the middle of it is not", {
        let events = scan([
            item("user-0", .user(AgentInbox.prompt("Look")), at: 0),
            item("text-1", .text("Reading the diff now."), at: 10),
            item("tool-2", .tool(name: "Bash", summary: "gh pr diff", detail: "", result: "...", isError: false, auto: true), at: 20),
            item("text-3", .text("The change is small and fine."), at: 30),
        ])
        check(events.map(\.kind) == [.prompt, .reply], "\(events.map(\.kind))")
        check(events[1].title == "Replied: The change is small and fine.", events[1].title)
        var scanner = TimelineScanner(session: "s", label: "L")
        scanner.update([item("text-1", .text("Working on it."), at: 0), item("tool-2", .tool(name: "Bash", summary: "x", detail: "", result: nil, isError: false, auto: true), at: 1)])
        check(scanner.events.isEmpty, "not the end of the turn yet")
        scanner.update([item("text-1", .text("Working on it."), at: 0)])
        check(scanner.events.map(\.kind) == [.reply], "the last item of the transcript ends the turn")
    }),
    ("timeline: permissions the user answered fold into one line, posted reviews and reports are events", {
        let permission: (String, Bool?, TimeInterval) -> AgentItem = { id, allowed, at in
            item(id, .permission(tool: "Bash", summary: "gh pr diff", detail: "", offer: [], allowed: allowed), at: at)
        }
        let items = [
            item("user-0", .user(AgentInbox.prompt("Go")), at: 0),
            permission("p1", true, 5), permission("p2", true, 6), permission("p3", false, 7), permission("p4", nil, 8),
            item("tool-9", .tool(name: "Bash", summary: "gh pr review \(pull) --comment -F review.md", detail: "", result: "ok", isError: false, auto: false), at: 20),
            item("tool-10", .tool(name: "Bash", summary: "gh pr review \(pull) --comment", detail: "", result: "no", isError: true, auto: false), at: 21),
            item("tool-11", .tool(name: "mcp__worktime__send_to_main", summary: "ACME-1: PASS", detail: "{}", result: "sent", isError: false, auto: false), at: 30),
        ]
        let events = scan(items)
        check(events.map(\.kind) == [.prompt, .approval, .posted, .reply], "\(events.map(\.kind))")
        check(events[1].count == 3 && events[1].title == "You answered 3 permission prompts" && events[1].item == "p1", "\(events[1])")
        check(events[1].detail?.contains("Refused") == true && events[1].detail?.contains("Allowed") == true, "\(String(describing: events[1].detail))")
        check(events[2].title == "Review posted on acme-com/orbit.api#12", events[2].title)
        check(events[3].title == "Reported to Main: ACME-1: PASS", events[3].title)
        check(Timeline.reviewCall("gh pr view \(pull)") == nil && Timeline.reviewCall("gh api repos/a/b/pulls/3/reviews -f body=x") == "a/b#3", "review calls")
    }),
    ("timeline: a session is read a changed item at a time, and a replaced transcript from the start", {
        var scanner = TimelineScanner(session: "s", label: "L")
        let first = item("user-0", .user(AgentInbox.prompt("One")), at: 0)
        check(scanner.update([first]) && scanner.events.count == 1, "first")
        check(!scanner.update([first]), "nothing new")
        let second = item("user-1", .user("Two"), at: 5)
        check(scanner.update([first, second]) && scanner.events.map(\.kind) == [.prompt, .feedback], "second")
        var streaming = item("text-2", .text("Half a sent"), at: 6)
        streaming.streaming = true
        scanner.update([first, second, streaming])
        check(scanner.events.count == 2, "a text still being written waits")
        streaming.streaming = false
        streaming.kind = .text("Done.")
        scanner.update([first, second, streaming])
        check(scanner.events.last?.title == "Replied: Done.", "\(scanner.events.map(\.title))")
        scanner.update([item("user-0", .user("Something else"), at: 100)])
        check(scanner.events.map(\.title) == ["You: Something else"], "replaced: \(scanner.events.map(\.title))")
        scanner.update([])
        check(scanner.events.isEmpty, "emptied")
    }),
    ("timeline: the sessions of a group are merged oldest first, ties in the order given", {
        func event(_ id: String, _ at: TimeInterval) -> TimelineEvent {
            TimelineEvent(id: id, session: id, sessionLabel: id, item: nil, date: start.addingTimeInterval(at), kind: .reply, title: id)
        }
        let merged = Timeline.merged([[event("a1", 0), event("a2", 30)], [event("b1", 10), event("b2", 30)], [event("c1", 5)]])
        check(merged.map(\.id) == ["a1", "c1", "b1", "a2", "b2"], "\(merged.map(\.id))")
        check(Timeline.merged([]).isEmpty, "none")
    }),
    ("timeline: reviews and comments the user posted come from the log of actions", {
        let request = GitHubActionRequest(.approve, repo: "acme-com/orbit.api", number: 12, title: "Add export", url: pull)
        var record = GitHubActionRecord(id: 7, at: start.addingTimeInterval(500), request: request, succeeded: true)
        record.actor = "niklas"
        record.via = "notification"
        record.sha = "abcdef1234567"
        let failed = GitHubActionRecord(id: 8, at: start, request: request, succeeded: false, error: "no")
        let merge = GitHubActionRecord(id: 9, at: start, request: GitHubActionRequest(.merge, repo: "acme-com/orbit.api", number: 12, title: "x", url: pull), succeeded: true)
        let other = GitHubActionRecord(id: 10, at: start, request: GitHubActionRequest(.approve, repo: "acme-com/other", number: 1, title: "y", url: "https://github.com/acme-com/other/pull/1"), succeeded: true)
        let events = Timeline.posted([record, failed, merge, other], url: { "https://github.com/\($0.repo)/pull/\($0.number)" },
                                     session: { $0 == pull ? ("topic:1", "Reviewer") : nil })
        check(events.count == 1, "only a successful review or comment on a pull request of the group: \(events.map(\.title))")
        check(events[0].kind == .posted && events[0].item == nil && events[0].session == "topic:1" && events[0].date == start.addingTimeInterval(500), "\(events[0])")
        check(events[0].title == "Approve on acme-com/orbit.api#12 by niklas from notification at abcdef1", events[0].title)
    }),
    ("timeline: restored sessions keep the times of the transcript", {
        let jsonl = [
            #"{"type":"user","timestamp":"2026-11-17T12:00:00.000Z","message":{"role":"user","content":"First"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-17T12:00:05.500Z","message":{"role":"assistant","content":[{"type":"text","text":"Reply"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"Undated"}}"#,
        ].joined(separator: "\n")
        let dated = AgentTranscript.datedLines(jsonl: jsonl)
        check(dated.count == 3 && dated[0].date != nil && dated[2].date == nil, "\(dated.map(\.date))")
        guard let first = dated[0].date, let second = dated[1].date else { return check(false, "dates") }
        check(abs(second.timeIntervalSince(first) - 5.5) < 0.001, "fractions of a second: \(second.timeIntervalSince(first))")
        let items = AgentTranscript.items(jsonl: jsonl, cwd: "/tmp")
        check(items.count == 3 && items[0].date == first && items[1].date == second, "\(items.map(\.date))")
        check(AgentTranscript.lines(jsonl: jsonl).count == 3, "lines are as before")
        var a = AgentItem(id: "x", kind: .user("same")), b = AgentItem(id: "x", kind: .user("same"))
        a.date = start
        b.date = start.addingTimeInterval(99)
        check(a == b, "the time is not part of what makes two items equal")
    }),
    ("timeline: an item is found in the transcript's blocks by its own id, or by the call its prompt was merged into", {
        let items = [
            item("user-0", .user("Go"), at: 0),
            item("p1", .permission(tool: "Bash", summary: "ls", detail: "", offer: [], allowed: true), at: 1, call: "c1"),
            item("t1", .tool(name: "Bash", summary: "ls", detail: "", result: "ok", isError: false, auto: false), at: 2, call: "c1"),
            item("text-3", .text("Done"), at: 3),
        ]
        check(AgentToolGroups.blockID(containing: "user-0", in: items) == "user-0", "a message")
        check(AgentToolGroups.blockID(containing: "text-3", in: items) == "text-3", "a reply")
        let viaCall = AgentToolGroups.blockID(containing: "p1", in: items)
        check(viaCall != nil && viaCall == AgentToolGroups.blockID(containing: "t1", in: items), "the permission shows in its tool row: \(String(describing: viaCall))")
        check(AgentToolGroups.blockID(containing: "nope", in: items) == nil, "unknown")
    }),
]
