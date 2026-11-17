import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let sessionA = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
private let sessionB = "3F2504E0-4F89-41D3-9A0C-0305E82C3302"
private let pr = "https://github.com/acme-com/orbit.api/pull/12"

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func agent(key: String = "topic:1", title: String = "Verifier \u{00B7} ACME-1", session: String? = sessionA, status: AgentState.Status = .idle, result: String? = nil,
                   ticket: String? = "ACME-1", updated: Date? = now, workspace: String = "work") -> AgentState {
    var state = AgentState(key: key, title: title, folder: "/Users/me/git/acme", sessionID: session, status: status, lastResult: result, updatedAt: updated)
    state.jiraKey = ticket
    state.workspace = workspace
    return state
}

private func decision(_ id: String = "approval:topic:1:p1", kind: PendingDecision.Kind = .permission, created: Date = now, session: String? = sessionA) -> PendingDecision {
    PendingDecision(id: id, kind: kind, title: "Verifier asks to run Bash", agent: "topic:1", session: session, created: created)
}

private func write(_ data: Data, _ url: URL) throws { try data.write(to: url, options: .atomic) }

private func write(agents: [AgentState], to url: URL) throws { try write(AgentOverview.encode(agents, now: now), url) }

private func sources(_ root: URL) -> MCPServer.CoordinatorSources {
    var sources = MCPServer.CoordinatorSources()
    sources.agentState = root.appendingPathComponent("agents.json")
    sources.decisions = root.appendingPathComponent("decisions.json")
    sources.timeline = root.appendingPathComponent("timeline.json")
    sources.appInfo = root.appendingPathComponent("app.json")
    sources.events = root.appendingPathComponent("events.json")
    sources.usage = root.appendingPathComponent("usage.jsonl")
    sources.inbox = root.appendingPathComponent("inbox", isDirectory: true)
    sources.notices = MCPServer.NoticeSources(file: root.appendingPathComponent("notices.json"), inbox: sources.inbox, replyTimeout: 3,
                                              source: { NoticeSource(session: "s1", cwd: "/Users/me/git/acme") })
    sources.alive = { $0 == 4242 }
    return sources
}

private func tool(_ name: String, _ tools: [MCPTool]) -> MCPTool { tools.first { $0.name == name }! }

private final class Clock: @unchecked Sendable {
    var date = now
}

private final class Inbox: @unchecked Sendable {
    var requests: [Data] = []
}

private func info(working: [AppInfo.Work] = [], queued: Int = 0, recording: Bool = false) -> AppInfo {
    AppInfo(written: now, version: "0.3.0", build: "120", commit: "abc1234", buildDate: nil, pid: 4242, started: now.addingTimeInterval(-93_600), dataFolder: "/data",
            schemaVersion: MCPServer.schemaVersion, workspaces: [AppInfo.Workspace(id: "work", name: "Work", spaces: ["Review", "Verify"])], sidecar: "built and Node.js found",
            working: working, waiting: [], queuedPrompts: queued, recording: recording, plan: nil, planFetched: nil)
}

private func event(_ kind: TimelineEvent.Kind, _ title: String, at offset: TimeInterval, detail: String? = nil, session: String = "topic:1", label: String = "Verifier") -> TimelineEvent {
    TimelineEvent(id: "\(session)|\(kind.rawValue)|\(offset)", session: session, sessionLabel: label, item: nil, date: now.addingTimeInterval(offset), kind: kind, title: title, detail: detail)
}

private func ticketGroup(_ events: [TimelineEvent], ticket: String = "ACME-1", prs: [String] = [], spaces: [String] = ["verify"]) -> TimelineGroup {
    var state = agent(ticket: ticket)
    state.spaces = spaces
    state.sessionPR = prs.first
    return TimelineSnapshots.group(TicketGroup(subject: .ticket(ticket), members: [state]), events: events, title: "Export invoices")
}

let coordinatorTests: [(name: String, run: () throws -> Void)] = [
    ("events: ids only grow, the file is capped and a cursor returns what came after", {
        var file = AppEvents.File()
        check(AppEvents.since(nil, limit: 10, in: file).events.isEmpty && AppEvents.since(nil, limit: 10, in: file).cursor == 0, "empty feed")
        let draft = { (text: String) in AppEvents.Draft(kind: .sessionFinished, text: text) }
        file = AppEvents.appending([draft("a"), draft("b")], to: file, now: now)
        check(file.events.map(\.id) == [Int(now.timeIntervalSince1970) + 1, Int(now.timeIntervalSince1970) + 2], "first ids are seconds, then grow")
        file = AppEvents.appending((0..<30).map { draft("n\($0)") }, to: file, now: now)
        let first = AppEvents.since(nil, limit: 5, in: file)
        check(first.events.count == AppEvents.latestCount && first.cursor == file.events.last?.id && first.events.last?.text == "n29", "no cursor: newest cursor and the last 20")
        let page = AppEvents.since(file.events[28].id, limit: 100, in: file)
        check(page.events.map(\.text) == ["n27", "n28", "n29"], "after the cursor \(page.events.map(\.text))")
        check(page.cursor == file.events.last?.id, "next cursor is the last event")
        let none = AppEvents.since(file.events.last!.id, limit: 10, in: file)
        check(none.events.isEmpty && none.cursor == file.events.last?.id, "nothing new keeps the cursor")
        check(AppEvents.since(file.events[0].id, limit: 2, in: file).events.count == 2, "limit")
        let big = AppEvents.appending((0..<(AppEvents.limit + 20)).map { draft("x\($0)") }, to: file, now: now)
        check(big.events.count == AppEvents.limit && big.events.last?.text == "x219", "capped, newest kept")
        check(AppEvents.decode(AppEvents.encode(big)) == big, "round trip")
        check(AppEvents.since(5, limit: 10, in: AppEvents.File()).cursor == 5, "an empty feed keeps the cursor")
    }),

    ("events: session, decision and review changes become events, and the first snapshot gives none", {
        let working = agent(status: .working), idle = agent(status: .idle, result: "PASS: export works"), waiting = agent(status: .waiting)
        var broken = agent(status: .error)
        broken.error = "Rate limited"
        check(AppEvents.sessionEvents(old: [], new: [working]).isEmpty, "a first snapshot compares with nothing known: a new key is not a transition")
        check(AppEvents.sessionEvents(old: [idle], new: [working]).map(\.kind) == [.sessionStarted], "idle to working")
        let done = AppEvents.sessionEvents(old: [working], new: [idle])
        check(done.map(\.kind) == [.sessionFinished] && done[0].text.contains("PASS: export works") && done[0].ticket == "ACME-1" && done[0].session == sessionA, "finished: \(done)")
        check(AppEvents.sessionEvents(old: [working], new: [waiting]).map(\.kind) == [.sessionWaiting], "waiting")
        check(AppEvents.sessionEvents(old: [working], new: [broken]).map(\.kind) == [.sessionErrored], "errored")
        check(AppEvents.sessionEvents(old: [working], new: [working]).isEmpty, "no change, no event")
        let raised = AppEvents.decisionEvents(old: [], new: [decision()]), answered = AppEvents.decisionEvents(old: [decision()], new: [])
        check(raised.map(\.kind) == [.decisionRaised] && answered.map(\.kind) == [.decisionAnswered], "decisions")
        let group = ticketGroup([event(.posted, "Approve on acme/orbit.api#12 by me", at: 5)], prs: [pr])
        let posted = AppEvents.postedEvents(known: [], groups: [group])
        check(posted.map(\.kind) == [.reviewPosted] && AppEvents.postedEvents(known: AppEvents.postedIDs([group]), groups: [group]).isEmpty, "a review posted once")
    }),

    ("pending_decisions: approvals, reuse questions, review drafts and automation asks are mapped with ids and links", {
        let state = agent(status: .waiting)
        var waiting = state
        waiting.pendingTool = "Bash"
        waiting.pendingInput = "npm test"
        let approval = DecisionApproval(agent: "topic:1", permission: "p1", kind: .call, title: "Verifier asks to run Bash", body: "npm test", created: now.addingTimeInterval(-120))
        let tool = DecisionApproval(agent: "topic:1", permission: "p2", kind: .roleTool, title: "Verifier wants jira_issue", body: "not in its tools", created: now.addingTimeInterval(-60))
        let blocked = DecisionApproval(agent: "topic:1", permission: "p3", kind: .blocked, title: "Turn stopped after refusals", body: "", created: now.addingTimeInterval(-30))
        let ask = TicketAsk(id: "ask-1", workspace: "work", assistant: "assistant:work:verifier", assistantName: "Verifier", ticket: "ACME-2", pullRequest: nil,
                            existing: TicketSessions.Preview(key: "topic:9", title: "ACME-2 \u{00B7} Verifier", state: "idle", updated: now, excerpt: "PASS earlier"),
                            text: "verify again", created: now.addingTimeInterval(-10), deadline: now.addingTimeInterval(1800))
        let draft = ReviewDraft(pr: pr, sha: "abcdef123456", verdict: .requestChanges, summary: "Two blockers.", comments: [ReviewDraft.Comment(path: "a.swift", line: 3, body: "x")])
        var reviewNotice = AgentNotice(id: "n1", title: "Review ready", urgency: .high, source: NoticeSource(agent: "routine:R1"), created: now.addingTimeInterval(-5))
        reviewNotice.reviews = [draft]
        var asking = AgentNotice(id: "n2", title: "Review requested in #reviews", source: NoticeSource(agent: "routine:R2"), created: now.addingTimeInterval(-3))
        asking.ask = NoticeAsk(routine: "R2", yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: "p", ticket: "ACME-3", pullRequest: pr)
        let quiet = AgentNotice(id: "n3", title: "FYI", source: NoticeSource(agent: "routine:R3"), created: now)
        let made = PendingDecisions.make(approvals: [approval, tool, blocked], ticketAsks: [ask], notices: [reviewNotice, asking, quiet], agents: [waiting], titles: [:])
        check(made.map(\.kind) == [.permission, .missingTool, .blocked, .reuseSession, .reviewDraft, .automationAsk], "oldest first, nothing for a quiet notice: \(made.map(\.kind))")
        let permission = made[0]
        check(permission.tool == "Bash" && permission.input == "npm test" && permission.ticket == "ACME-1" && permission.session == sessionA
              && permission.id == "approval:topic:1:p1" && permission.link == "worktime://open?agent=topic%3A1", "permission: \(permission)")
        let reuse = made[3]
        check(reuse.ticket == "ACME-2" && reuse.role == "Verifier" && reuse.preview == "PASS earlier" && reuse.link == "worktime://open?ticket=ACME-2" && reuse.id == "ask:ask-1", "reuse: \(reuse)")
        let review = made[4]
        check(review.pullRequest == pr && review.verdict == "request_changes" && review.comments == 1 && review.link?.hasPrefix("worktime://pr?url=") == true, "review: \(review)")
        check(made[5].ticket == "ACME-3" && made[5].pullRequest == pr, "automation ask")
        let file = PendingDecisions.File(written: now, decisions: made)
        check(PendingDecisions.decode(PendingDecisions.encode(made, now: now)) == file, "round trip")
        let text = PendingDecisions.markdown(file, now: now)
        check(text.contains("Only they can answer them") && text.contains("npm test") && text.contains("worktime://open?ticket=ACME-2") && text.contains("2 min"), text)
        check(PendingDecisions.markdown(PendingDecisions.File(written: now, decisions: []), now: now).hasPrefix("Nothing waits"), "empty")
        check(PendingDecisions.markdown(PendingDecisions.File(written: now.addingTimeInterval(-900), decisions: []), now: now).contains("may not be running"), "stale")
    }),

    ("pending_decisions is read-only: it leaves the inbox alone and the write tools are the known set, none of which answers a decision", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = sources(root)
        try write(PendingDecisions.encode([decision()], now: now), s.decisions)
        let tools = MCPServer.coordinatorTools(sources: s, now: { now })
        let pending = tool("pending_decisions", tools)
        check(pending.readOnly && pending.description.contains("READ-ONLY") && pending.description.contains("no tool answers"), "described as read-only")
        let answer = try pending.run([:])
        check(answer.contains("Verifier asks to run Bash"), answer)
        check(((try? FileManager.default.contentsOfDirectory(atPath: s.inbox.path)) ?? []).isEmpty, "nothing was left in the inbox")
        check((try? pending.run(["kind": "bogus"])) == nil, "an unknown kind is an error")
        check(try pending.run(["kind": "blocked"]).contains("Nothing waits"), "filtered")
        let writing = Set(MCPServer.allTools.filter { !$0.readOnly }.map(\.name))
        let known: Set = ["send_to_agent", "send_to_main", "notify", "cancel_notification", "add_reminder", "complete_reminder", "create_routine", "update_routine", "set_routine_enabled",
                          "delete_routine", "analyze_routine", "compile_routine", "create_automation", "update_automation", "delete_automation", "create_assistant", "update_assistant",
                          "delete_assistant", "create_workspace", "update_workspace", "create_space", "update_space", "delete_space", "tag_session", "open_in_app"]
        check(writing.isSubset(of: known), "a new write tool must be added here on purpose: \(writing.subtracting(known).sorted())")
        let answering = MCPServer.toolNames.filter { name in ["approve", "allow", "deny", "answer", "respond", "decide", "resolve", "dismiss", "post_review", "merge"].contains { name.contains($0) } }
        check(answering.isEmpty, "no tool names an answer: \(answering)")
        for name in ["pending_decisions", "wait_for", "request_status", "events_since", "ticket_timeline", "outcomes", "app_info", "usage_summary", "workspaces"] {
            check(MCPServer.allTools.first { $0.name == name }?.readOnly == true, "\(name) is read-only")
        }
        let routes = ["approval", "decision", "answer"]
        check(!MCPServer.allTools.contains { tool in
            !tool.readOnly && tool.properties.keys.contains { key in routes.contains { key.contains($0) } }
        }, "no write tool takes an argument that names a decision")
    }),

    ("request_status: pending, answered, created, started, timed_out and refused, with the session and ticket once known", {
        let request = AgentInbox.Request(id: sessionB, agent: "assistant:work:verifier", text: "go", created: now, ticket: "ACME-1")
        let record = RequestStatuses.record(for: request, target: "Verifier", role: "Verifier", waitsForUser: true, waitSeconds: 1800, now: now)
        check(record.deadline == now.addingTimeInterval(1860), "the deadline is the user's wait and a minute")
        func status(_ reply: AgentInbox.Reply? = nil, inInbox: Bool = false, decisions: [PendingDecision] = [], at offset: TimeInterval = 0, agents: [AgentState] = []) -> RequestStatus {
            RequestStatuses.status(record, reply: reply, inInbox: inInbox, decisions: decisions, agents: agents, now: now.addingTimeInterval(offset))
        }
        check(status(inInbox: true).state == .pending && status(inInbox: true).message.contains("not picked"), "waiting for the app")
        check(status(inInbox: true, at: 1900).state == .timedOut && status(inInbox: true, at: 1900).message.contains("Is the app running"), "the app never took it")
        let asked = status(decisions: [decision("ask:" + sessionB, kind: .reuseSession)], at: 100)
        check(asked.state == .pending && asked.waitingForUser, "the user has the question")
        check(status(at: 1).state == .pending && status(at: 10).state == .answered, "no question any more: answered")
        check(status(at: 2000).state == .timedOut, "nobody answered in time")
        let created = status(AgentInbox.Reply(id: sessionB, status: .started, sessionID: sessionA, message: "started", note: "Started a new session.", created: true), agents: [agent()])
        check(created.state == .created && created.sessionID == sessionA && created.ticket == "ACME-1" && created.sessionKey == "topic:1" && created.isFinal, "created: \(created)")
        check(status(AgentInbox.Reply(id: sessionB, status: .queued, sessionID: sessionA, message: "queued")).state == .started, "queued in an existing session is started")
        check(status(AgentInbox.Reply(id: sessionB, status: .rejected, message: "No.")).state == .refused, "refused")
        check(status(AgentInbox.Reply(id: sessionB, status: .rejected, message: "No answer.", timedOut: true)).state == .timedOut, "timed out")
        check(RequestStatuses.markdown(created).contains("state: created") && RequestStatuses.markdown(created).contains("This is final."), "text")
        check(RequestStatuses.markdown(asked).contains("only they can answer"), "tells who can answer")
    }),

    ("send_to_agent with async leaves the prompt and a record, and request_status follows it to the app's reply", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var agents = MCPServer.AgentSources()
        agents.inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let request = AgentInbox.Request(id: sessionB, agent: pr, text: "look", created: now)
        let began = try MCPServer.submit(request, title: "orbit.api#12", role: nil, waitsForUser: false, wait: false, sources: agents, timeout: 1, now: now)
        check(began.contains("request_id: \(sessionB)") && began.contains("state: pending"), began)
        let names = try FileManager.default.contentsOfDirectory(atPath: agents.inbox.path).sorted()
        check(Set(names) == [AgentInbox.requestName(sessionB), RequestStatuses.recordName(sessionB)], "\(names)")
        var s = sources(root)
        s.inbox = agents.inbox
        let status = tool("request_status", MCPServer.coordinatorTools(sources: s, now: { now }))
        check(try status.run(["request_id": sessionB]).contains("state: pending"), "pending while in the inbox")
        try FileManager.default.removeItem(at: agents.inbox.appendingPathComponent(AgentInbox.requestName(sessionB)))
        try write(AgentInbox.encode(AgentInbox.Reply(id: sessionB, status: .started, sessionID: sessionA, message: "started")), agents.inbox.appendingPathComponent(AgentInbox.replyName(sessionB)))
        check(try status.run(["request_id": sessionB]).contains("state: started"), "started once the app replied")
        check((try? status.run(["request_id": "not-an-id"])) == nil && (try? status.run(["request_id": sessionA])) == nil, "an unknown or malformed id is an error")
        check(tool("send_to_agent", MCPServer.agentTools(.failure(MCPToolError("")), sources: agents)).properties["async"] != nil, "send_to_agent takes async")
    }),

    ("send_to_agent with agent Main hands the workspace's Main a message labelled from Claude Code", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        var agents = MCPServer.AgentSources()
        agents.notices = MCPServer.NoticeSources(file: root.appendingPathComponent("n.json"), inbox: inbox, replyTimeout: 3,
                                                 source: { NoticeSource(session: "s1", cwd: "/Users/me/git/acme") })
        let received = Inbox()
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let name = ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).first(where: AgentReports.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)), let request = AgentInbox.decode(ReportRequest.self, from: data) {
                    received.requests.append(data)
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    try? AgentInbox.encode(NoticeReply(id: request.id, ok: true, notice: nil, message: "Sent to the Main of work; it is reading it now."))
                        .write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let send = tool("send_to_agent", MCPServer.agentTools(.failure(MCPToolError("")), sources: agents, now: { now }))
        let answer = try send.run(["agent": "Main", "workspace": "work", "text": "status of ACME-1?"])
        check(answer.contains("Main of work"), answer)
        guard let data = received.requests.first, let sent = AgentInbox.decode(ReportRequest.self, from: data) else { return check(false, "a report request was left") }
        check(sent.workspace == "work" && sent.text == "status of ACME-1?" && sent.source.cwd == "/Users/me/git/acme", "\(sent)")
        let workspaces = Workspaces.sample
        switch AgentReports.decide(sent, workspaces: workspaces, titles: [:], queued: { _ in [] }, ledger: AgentReports.Ledger(), now: now) {
        case .deliver(let workspace, let name, let prompt):
            check(workspace == "work" && name == "Claude Code \u{00B7} acme" && prompt == "Report from Claude Code \u{00B7} acme: status of ACME-1?", "\(name) \(prompt)")
            check(AgentSessions.title(prompt: prompt) == "From Claude Code \u{00B7} acme: status of ACME-1?", "shown as from Claude Code")
        default: check(false, "delivered")
        }
        var fromMain = sent
        fromMain.source = NoticeSource(agent: "main:work", workspace: "work")
        check(AgentReports.decide(fromMain, workspaces: workspaces, titles: [:], queued: { _ in [] }, ledger: AgentReports.Ledger(), now: now) == .reject("You are the Main of Work; a report goes to a Main from another agent. Say it in your own reply."), "a Main cannot message its own Main")
        check(MCPServer.mainAddress(["agent": "main"]) == .some(nil) && MCPServer.mainAddress(["agent": "Main", "workspace": "work"]) == .some("work"), "Main by name")
        check(MCPServer.mainAddress(["agent": "main:reviews"]) == .some("reviews") && MCPServer.mainAddress(["agent": "Reviewer"]) == nil, "a Main's key, and other agents")
        check(MCPServer.mainAddress(["agent": "Main", "pr_url": pr]) == nil, "a pull request names another agent")
    }),

    ("wait_for returns when the agent finishes, needs the user, changes or the time is up, without real waiting", {
        let clock = Clock()
        func run(_ target: WaitTarget, until: WaitUntil, timeout: TimeInterval, steps: [WaitSnapshot]) -> WaitResult {
            var index = 0
            clock.date = now
            return WaitFor.run(target, until: until, timeout: timeout, read: { defer { index = min(index + 1, steps.count - 1) }; return steps[index] },
                               sleep: { clock.date = clock.date.addingTimeInterval($0) }, now: { clock.date })
        }
        func snapshot(_ states: [AgentState], _ decisions: [PendingDecision] = [], request: RequestStatus? = nil) -> WaitSnapshot { WaitSnapshot(agents: states, decisions: decisions, request: request) }
        let working = agent(status: .working), done = agent(status: .idle, result: "PASS: ok"), session = WaitTarget(session: sessionA)
        let finished = run(session, until: .finished, timeout: 60, steps: [snapshot([working]), snapshot([working]), snapshot([done])])
        check(finished.reason == "finished" && finished.members.first?.lastResult == "PASS: ok" && finished.waited >= 1 && finished.waited < 5, "finished: \(finished.reason) \(finished.waited)")
        check(WaitFor.markdown(finished, now: now).contains("Last result of") && WaitFor.markdown(finished, now: now).contains("PASS: ok"), "last result in the answer")
        let slow = run(session, until: .finished, timeout: 3, steps: [snapshot([working])])
        check(slow.reason == "timed_out" && slow.waited >= 3 && slow.waited < 4, "times out at the limit: \(slow.waited)")
        check(run(session, until: .idle, timeout: 60, steps: [snapshot([agent(status: .idle)])]).reason == "idle", "idle without a result")
        check(run(session, until: .finished, timeout: 2, steps: [snapshot([agent(status: .idle)])]).reason == "timed_out", "finished needs a result")
        let needs = run(session, until: .needsYou, timeout: 60, steps: [snapshot([working]), snapshot([agent(status: .waiting)])])
        check(needs.reason == "needs_you", "needs you")
        check(run(session, until: .finished, timeout: 60, steps: [snapshot([working]), snapshot([agent(status: .waiting)])]).reason == "needs_you", "finished also returns for the user's question")
        let asked = run(session, until: .idle, timeout: 60, steps: [snapshot([agent(status: .idle)], [decision("ask:x", kind: .reuseSession)])])
        check(asked.reason == "needs_you" && asked.decisions.count == 1, "a decision waiting on the session")
        let changed = run(session, until: .any, timeout: 60, steps: [snapshot([working]), snapshot([working]), snapshot([done])])
        check(changed.reason == "changed", "any change")
        check(run(session, until: .any, timeout: 2, steps: [snapshot([done])]).reason == "timed_out", "any waits for a change")
        let ticket = WaitTarget(ticket: "ACME-1")
        check(run(ticket, until: .finished, timeout: 60, steps: [snapshot([working, agent(key: "topic:2", title: "Reviewer \u{00B7} ACME-1", session: sessionB, status: .idle, result: "x")]),
                                                                 snapshot([done, agent(key: "topic:2", title: "Reviewer \u{00B7} ACME-1", session: sessionB, status: .idle, result: "x")])]).reason == "finished", "a ticket's agents")
        var record = RequestStatuses.record(for: AgentInbox.Request(id: sessionB, agent: "a", text: "t", created: now), target: "x", role: nil, waitsForUser: true, waitSeconds: 60, now: now)
        record.created = now
        var started = RequestStatus(id: sessionB, state: .started, message: "", sessionID: sessionA)
        started.sessionID = sessionA
        let stale = agent(status: .idle, result: "old", updated: now.addingTimeInterval(-600))
        let after = run(WaitTarget(request: record), until: .finished, timeout: 5, steps: [snapshot([stale], request: started)])
        check(after.reason == "timed_out", "a state file from before the request is not its end")
        let fresh = agent(status: .idle, result: "new", updated: now.addingTimeInterval(2))
        check(run(WaitTarget(request: record), until: .finished, timeout: 5, steps: [snapshot([stale], request: started), snapshot([fresh], request: started)]).reason == "finished", "after the request it counts")
        let refused = RequestStatus(id: sessionB, state: .refused, message: "No.")
        check(run(WaitTarget(request: record), until: .finished, timeout: 5, steps: [snapshot([], request: refused)]).reason == "refused", "a refused request ends the wait")
        var asking = RequestStatus(id: sessionB, state: .pending, message: "")
        asking.waitingForUser = true
        check(run(WaitTarget(request: record), until: .finished, timeout: 5, steps: [snapshot([], request: asking)]).reason == "needs_you", "the reuse question is for the user")
        check(WaitFor.timeout(nil) == 120 && WaitFor.timeout(5000) == 600 && WaitFor.timeout(0) == 1 && WaitFor.timeout("30") == 30, "timeout bounds")
    }),

    ("wait_for as a tool never waits past its timeout and rejects ambiguous targets", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var s = sources(root)
        let clock = Clock()
        s.sleep = { clock.date = clock.date.addingTimeInterval($0) }
        try write(agents: [agent(status: .working)], to: s.agentState)
        let wait = tool("wait_for", MCPServer.coordinatorTools(sources: s, now: { clock.date }))
        check(wait.readOnly && wait.properties["timeout_seconds"]?["maximum"] as? Int == 600, "read-only, at most 600 seconds")
        let answer = try wait.run(["session_id": sessionA, "timeout_seconds": 4])
        check(answer.contains("result: timed_out") && clock.date.timeIntervalSince(now) < 5, answer)
        check((try? wait.run([:])) == nil && (try? wait.run(["session_id": sessionA, "ticket": "ACME-1"])) == nil && (try? wait.run(["ticket": "nope"])) == nil, "exactly one target")
        try write(agents: [agent(status: .idle, result: "PASS: done")], to: s.agentState)
        check(try wait.run(["ticket": "ACME-1", "until": "finished"]).contains("result: finished"), "returns at once when already finished")
        check((try? wait.run(["session_id": sessionA, "until": "sometime"])) == nil, "an unknown until")
        check(MCPServer.networkTools.contains("wait_for") && MCPServer.networkTools.contains("send_to_agent"), "served beside the next messages")
    }),

    ("ticket_timeline and outcomes read the app's snapshot: events in order, the latest verdict per ticket, filters", {
        let verdictFail = event(.outcome, "FAIL: export is wrong", at: 100, detail: "FAIL: export is wrong\nThe CSV has no header.")
        let verdictPass = event(.outcome, "PASS: export works", at: 300, detail: "PASS: export works")
        let one = ticketGroup([event(.trigger, "Triggered by Slack message in #verify", at: 0), event(.prompt, "Main asked: verify ACME-1", at: 10), verdictFail,
                               event(.feedback, "You: try again", at: 200), verdictPass, event(.posted, "Approve on orbit.api#12 by me", at: 400, label: "Reviewer")], prs: [pr])
        check(one.outcome?.verdict == "PASS" && one.outcome?.text == "PASS: export works" && one.events.count == 6, "latest outcome: \(String(describing: one.outcome))")
        check(one.ticket == "ACME-1" && one.title == "Export invoices" && one.spaces == ["verify"] && one.sessions == [sessionA], "group fields")
        let advice = ticketGroup([event(.outcome, "Recommendation: review - small change", at: 50, detail: "Recommendation: review - small change")], ticket: "ACME-2", spaces: ["review"])
        check(advice.outcome?.verdict == "Recommendation", "a recommendation")
        let blocked = ticketGroup([event(.outcome, "BLOCKED: needs a token", at: 500, detail: "BLOCKED: needs a token")], ticket: "ACME-3")
        let none = ticketGroup([event(.prompt, "Main asked: x", at: 1)], ticket: "ACME-4")
        check(none.outcome == nil, "no outcome yet")
        let table = TimelineSnapshots.outcomes([one, advice, blocked, none], now: now.addingTimeInterval(3600))
        let rows = table.split(separator: "\n").map(String.init)
        check(rows.count == 6 && rows[2].hasPrefix("| ACME-3 | BLOCKED") && rows[3].hasPrefix("| ACME-1 | PASS") && rows[4].hasPrefix("| ACME-2 | Recommendation") && rows[5].contains("none yet"), table)
        check(TimelineSnapshots.outcomes([one, advice], ticket: "ACME-2", now: now).contains("ACME-2") && !TimelineSnapshots.outcomes([one, advice], ticket: "ACME-2", now: now).contains("ACME-1"), "ticket filter")
        check(!TimelineSnapshots.outcomes([one, advice], space: "review", now: now).contains("ACME-1"), "space filter")
        check(TimelineSnapshots.outcomes([one, advice], since: now.addingTimeInterval(200), now: now).contains("ACME-1")
              && !TimelineSnapshots.outcomes([one, advice], since: now.addingTimeInterval(200), now: now).contains("ACME-2"), "since filter")
        check(TimelineSnapshots.outcomes([], now: now) == "No outcomes match.\n", "nothing")
        let text = TimelineSnapshots.markdown(one, now: now.addingTimeInterval(500))
        check(text.contains("Latest outcome: **PASS**") && text.contains("Triggered by Slack message") && text.contains("Review posted") == false && text.contains("Approve on orbit.api#12"), text)
        check(text.range(of: "outcome \u{00B7} FAIL: export is wrong")!.lowerBound < text.range(of: "outcome \u{00B7} PASS: export works")!.lowerBound, "oldest first")
        let capped = TimelineSnapshots.group(TicketGroup(subject: .ticket("ACME-9"), members: [agent(ticket: "ACME-9")]),
                                             events: (0..<(TimelineSnapshots.eventLimit + 30)).map { event(.reply, "r\($0)", at: Double($0)) })
        check(capped.events.count == TimelineSnapshots.eventLimit && capped.events.last?.title == "r109", "events capped, newest kept")
        let many = (0..<(TimelineSnapshots.groupLimit + 5)).map { index -> TimelineGroup in var group = none; group.key = "ticket:T-\(index)"; group.updated = now.addingTimeInterval(Double(index)); return group }
        check(TimelineSnapshots.capped(many).count == TimelineSnapshots.groupLimit && TimelineSnapshots.capped(many).first?.key == "ticket:T-64", "groups capped, newest first")
        check(TimelineSnapshots.find(ticket: "acme-1", pullRequest: nil, in: [one])?.label == "ACME-1" && TimelineSnapshots.find(ticket: nil, pullRequest: pr, in: [one]) != nil, "found by ticket or a pull request of it")
        check(TimelineSnapshots.find(ticket: nil, pullRequest: "https://github.com/acme-com/x/pull/1", in: [one]) == nil, "unknown pull request")
    }),

    ("ticket_timeline, outcomes and events_since as tools read the files and say when the app has not written them", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = sources(root)
        let tools = MCPServer.coordinatorTools(sources: s, now: { now.addingTimeInterval(600) })
        check((try? tool("ticket_timeline", tools).run(["ticket": "ACME-1"])) == nil && (try? tool("outcomes", tools).run([:])) == nil, "no file yet is an error that says so")
        let group = ticketGroup([event(.outcome, "PASS: export works", at: 300, detail: "PASS: export works")], prs: [pr])
        try write(TimelineSnapshots.encode([group], now: now), s.timeline)
        check(try tool("ticket_timeline", tools).run(["ticket": "ACME-1"]).contains("PASS: export works"), "by ticket")
        check(try tool("ticket_timeline", tools).run(["pr_url": pr]).contains("## ACME-1"), "by pull request")
        check(try tool("ticket_timeline", tools).run(["ticket": "ACME-77"]).hasPrefix("No timeline for ACME-77"), "unknown ticket")
        check((try? tool("ticket_timeline", tools).run([:])) == nil && (try? tool("ticket_timeline", tools).run(["ticket": "ACME-1", "pr_url": pr])) == nil, "exactly one of ticket and pr_url")
        check(try tool("outcomes", tools).run(["ticket": "ACME-1"]).contains("| ACME-1 | PASS"), "outcomes")
        check((try? tool("outcomes", tools).run(["ticket": "nope"])) == nil, "a bad ticket")
        let events = tool("events_since", tools)
        check(try events.run([:]).contains("No events yet."), "no feed yet")
        try write(AppEvents.encode(AppEvents.appending([AppEvents.Draft(kind: .sessionStarted, text: "Verifier: started working", ticket: "ACME-1")], to: AppEvents.File(), now: now)), s.events)
        let first = try events.run([:])
        let cursor = Int(now.timeIntervalSince1970) + 1
        check(first.hasPrefix("cursor: \(cursor) (newest") && first.contains("session_started") && first.contains("ACME-1"), first)
        check(try events.run(["cursor": cursor]).contains("Nothing new.") && (try events.run(["cursor": cursor - 1])).contains("session_started"), "after the cursor")
    }),

    ("app_info: version, commit, uptime, workspaces, sidecar and whether a restart would interrupt work", {
        let quiet = AppInfos.markdown(info(), now: now, alive: true, mcpSchema: MCPServer.schemaVersion)
        check(quiet.contains("WorkTime 0.3.0 (build 120) \u{00B7} commit abc1234") && quiet.contains("pid 4242") && quiet.contains("up 1d 2h") && quiet.contains("data folder: /data"), quiet)
        check(quiet.contains("workspaces: work (spaces: Review, Verify)") && quiet.contains("sidecar: built and Node.js found") && quiet.contains("would not interrupt"), quiet)
        let busy = AppInfos.markdown(info(working: [AppInfo.Work(kind: "ticket_session", title: "Verifier \u{00B7} ACME-1", session: sessionA, ticket: "ACME-1", since: now)], queued: 2, recording: true),
                                     now: now, alive: true, mcpSchema: MCPServer.schemaVersion)
        check(busy.contains("WOULD interrupt") && busy.contains("Verifier \u{00B7} ACME-1 (ACME-1) session \(sessionA)") && busy.contains("2 queued prompts") && busy.contains("a meeting recording"), busy)
        check(AppInfos.markdown(info(), now: now, alive: false, mcpSchema: 1).contains("not running") && AppInfos.markdown(info(), now: now, alive: true, mcpSchema: 1).contains("reconnect the worktime MCP"), "a dead process, an older connection")
        check(AppInfos.markdown(info(), now: now.addingTimeInterval(600), alive: true, mcpSchema: MCPServer.schemaVersion).contains("may not be running"), "a stale file")
        var dated = info()
        dated.commit = nil
        dated.buildDate = now
        check(AppInfos.markdown(dated, now: now, alive: true, mcpSchema: MCPServer.schemaVersion).contains("built "), "the build date when there is no commit")
        let work = AppInfos.work([agent(status: .working), agent(key: "topic:2", session: sessionB, status: .waiting), agent(key: "topic:3", status: .idle)], routines: ["Morning"])
        check(work.working.map(\.title) == ["Verifier \u{00B7} ACME-1", "Morning"] && work.waiting.count == 1 && AppInfos.restartInterrupts(info(working: work.working)), "work")
        check(AppInfos.decode(AppInfos.encode(info())) == info(), "round trip")
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = sources(root)
        let appInfo = tool("app_info", MCPServer.coordinatorTools(sources: s, now: { now }))
        check((try? appInfo.run([:])) == nil, "not written yet")
        try write(AppInfos.encode(info()), s.appInfo)
        check(try appInfo.run([:]).contains("pid 4242"), "read from the file")
    }),

    ("usage_summary adds up the log by range and group, with the plan's windows when cached", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = sources(root)
        let log = UsageLog(url: s.usage)
        let noon = now.addingTimeInterval(4 * 3600)
        func totals(_ cost: Double, model: String = "claude-sonnet-4-6") -> UsageTotals {
            UsageTotals(models: [model: UsageModelTotals(input: 1000, output: 500, cacheRead: 0, cacheWrite: 0, cost: cost)], reportedCost: cost)
        }
        log.append(UsageRecord(id: "1", date: noon.addingTimeInterval(-3600), session: nil, kind: .assistant, key: "assistant:work:verifier", name: "Verifier", workspace: "Work", totals: totals(1.5)))
        log.append(UsageRecord(id: "2", date: noon.addingTimeInterval(-1800), session: nil, kind: .routine, key: "routine:r", name: "Morning", workspace: "Personal", totals: totals(0.25, model: "claude-haiku-4-5")))
        log.append(UsageRecord(id: "3", date: noon.addingTimeInterval(-86_400 * 3), session: nil, kind: .main, key: "main:work", name: "Main", workspace: "Work", totals: totals(2)))
        let usage = tool("usage_summary", MCPServer.coordinatorTools(sources: s, now: { noon }))
        let today = try usage.run([:])
        check(today.contains("$1.75") && today.contains("2 calls") && today.contains("| Work | $1.50") && today.contains("| Personal | $0.25"), today)
        check(today.contains("not cached"), "no plan windows without the app's file")
        let week = try usage.run(["range": "7d", "group_by": "agent"])
        check(week.contains("$3.75") && week.contains("| Verifier |") && week.contains("| Main |"), week)
        check(try usage.run(["group_by": "routine"]).contains("| Morning |") && (try usage.run(["group_by": "model"])).contains("Haiku"), "routine and model")
        check(try usage.run(["group_by": "automation"]).contains("Nothing to group by automation"), "an empty group")
        check((try? usage.run(["range": "year"])) == nil && (try? usage.run(["group_by": "colour"])) == nil, "bad arguments")
        var withPlan = info()
        withPlan.plan = [AppInfo.PlanWindow(title: "5-hour limit", percent: 42, resets: now.addingTimeInterval(7200))]
        withPlan.planFetched = noon
        withPlan.plan = [AppInfo.PlanWindow(title: "5-hour limit", percent: 42, resets: noon.addingTimeInterval(7200))]
        try write(AppInfos.encode(withPlan), s.appInfo)
        check(try usage.run([:]).contains("5-hour limit 42%, resets in 2h"), "plan windows")
        let lines = try String(contentsOf: s.usage, encoding: .utf8).split(separator: "\n").count
        check(UsageLog(url: s.usage).read(now: noon).count == 3 && lines == 3, "reading does not rewrite the log")
    }),

    ("workspaces: create and update are checked like Settings, and the app applies a change at once", {
        let file = WorkspaceFile(workspaces: Workspaces.sample)
        func handle(_ action: WorkspaceRequest.Action, workspace: String? = nil, draft: WorkspaceDraft? = nil, space: String? = nil, spaceDraft: SpaceDraft? = nil, session: String? = nil,
                    ticket: String? = nil, spaces: [String]? = nil, store: WorkspaceFile = file, agents: [AgentState] = [], caller: String? = "work", created: Date = now)
            -> (reply: NoticeReply, change: WorkspaceChange?) {
            WorkspaceRequests.handle(WorkspaceRequest(id: UUID().uuidString, action: action, workspace: workspace, draft: draft, space: space, spaceDraft: spaceDraft, session: session, ticket: ticket,
                                                      spaces: spaces, source: NoticeSource(agent: nil, workspace: caller), created: created), file: store, agents: agents, now: now, home: "/Users/me")
        }
        let made = handle(.createWorkspace, draft: WorkspaceDraft(name: "Reviews", symbol: "checkmark.seal", color: "orange", roots: ["~/git/reviews/", "~/git/reviews"],
                                                                 githubOwners: ["acme-com"], jiraProjects: ["rev", "REV"], slack: true, extraFiles: ["~/notes/reviews.md"]))
        guard case .create(let workspace)? = made.change else { return check(false, "created: \(made.reply.message)") }
        check(workspace.id == "reviews" && workspace.roots == ["~/git/reviews"] && workspace.jiraProjects == ["REV"] && workspace.slack == "Reviews" && workspace.color == "orange"
              && workspace.symbol == "checkmark.seal" && made.reply.notice == "reviews", "\(workspace)")
        check(made.reply.message.contains("ready now") && made.reply.message.contains("also a folder") == false, made.reply.message)
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "work")).reply.ok == false && handle(.createWorkspace, draft: WorkspaceDraft(name: " WORK ")).change == nil, "a name that is taken")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "")).reply.message == "name is empty." && handle(.createWorkspace, draft: WorkspaceDraft(name: String(repeating: "x", count: 41))).reply.ok == false, "name length")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "A", roots: ["relative/path"])).reply.message.contains("absolute"), "roots must be absolute or ~/")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "A", jiraProjects: ["1bad"])).reply.message.contains("project keys"), "jira keys")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "A", githubOwners: ["not an owner"])).reply.message.contains("GitHub"), "github owners")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "A", symbol: "Not A Symbol")).reply.message.contains("SF Symbol"), "symbols")
        check(handle(.createWorkspace, draft: WorkspaceDraft(id: "Bad Id", name: "A")).reply.ok == false && handle(.createWorkspace, draft: WorkspaceDraft(id: "work", name: "A")).reply.ok == false, "ids")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "Overlap", roots: ["~/git/inde"])).reply.message.contains("also a folder of another workspace"), "an overlapping folder is said")
        let many = WorkspaceFile(workspaces: (0..<WorkspaceRequests.workspaceLimit).map { Workspace(id: "w\($0)", name: "W\($0)", symbol: "folder", color: "blue", roots: [], githubOwners: [], jiraProjects: [], slack: nil, extraFiles: []) })
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "One more"), store: many).reply.message.contains("limit"), "the limit")
        check(handle(.createWorkspace, draft: WorkspaceDraft(name: "Late"), created: now.addingTimeInterval(-600)).reply.message == "The request is too old.", "stale requests")
        let updated = handle(.updateWorkspace, workspace: "Personal", draft: WorkspaceDraft(name: "Home", jiraProjects: ["home"], slack: false))
        guard case .update(let home)? = updated.change else { return check(false, "updated: \(updated.reply.message)") }
        check(home.name == "Home" && home.jiraProjects == ["HOME"] && home.id == "personal" && home.roots == ["~/git/inde"], "only what was given changes: \(home)")
        check(handle(.updateWorkspace, workspace: "Personal", draft: WorkspaceDraft(name: "Work")).reply.message.contains("already called"), "another workspace's name")
        check(handle(.updateWorkspace, workspace: "nope", draft: WorkspaceDraft(name: "x")).reply.ok == false, "unknown workspace")
        check(handle(.updateWorkspace, workspace: nil, draft: WorkspaceDraft(color: "red"), caller: "personal").change != nil, "the caller's own workspace by default")
        check(handle(.updateWorkspace, workspace: nil, draft: WorkspaceDraft(color: "red"), caller: nil).reply.message.contains("workspace is required"), "outside a Main a workspace is needed")
        check(WorkspaceRequests.markdown(Workspaces.sample).contains("owners (GitHub): acme-com") && WorkspaceRequests.markdown(Workspaces.sample, only: "personal").contains("Personal") == true
              && !WorkspaceRequests.markdown(Workspaces.sample, only: "personal").contains("acme-com") && WorkspaceRequests.markdown(Workspaces.sample, only: "zzz").hasPrefix("No workspace"), "listing")
    }),

    ("workspaces: spaces are created, renamed, deleted and tagged onto sessions with the same checks", {
        var work = Workspaces.sample[0]
        work.spaces = [Space(id: "review", name: "Review", icon: "eye", color: "orange")]
        let file = WorkspaceFile(workspaces: [work, Workspaces.sample[1]])
        func handle(_ action: WorkspaceRequest.Action, space: String? = nil, draft: SpaceDraft? = nil, session: String? = nil, ticket: String? = nil, spaces: [String]? = nil, agents: [AgentState] = [])
            -> (reply: NoticeReply, change: WorkspaceChange?) {
            WorkspaceRequests.handle(WorkspaceRequest(id: UUID().uuidString, action: action, workspace: "work", draft: nil, space: space, spaceDraft: draft, session: session, ticket: ticket,
                                                      spaces: spaces, source: NoticeSource(), created: now), file: file, agents: agents, now: now)
        }
        guard case .update(let added)? = handle(.createSpace, draft: SpaceDraft(name: "Verify", icon: "checkmark.seal", color: "green")).change else { return check(false, "create_space") }
        check(added.spaces.map(\.id) == ["review", "verify"] && added.spaces[1].icon == "checkmark.seal" && added.spaces[1].color == "green", "\(added.spaces)")
        check(handle(.createSpace, draft: SpaceDraft(name: "review")).reply.message.contains("exists") && handle(.createSpace, draft: SpaceDraft()).reply.message == "name is required.", "duplicate and missing names")
        check(handle(.createSpace, draft: SpaceDraft(name: "X", icon: "No Symbol")).reply.ok == false, "icon")
        guard case .update(let renamed)? = handle(.updateSpace, space: "REVIEW", draft: SpaceDraft(name: "Code review", color: "purple")).change else { return check(false, "update_space") }
        check(renamed.spaces[0].id == "review" && renamed.spaces[0].name == "Code review" && renamed.spaces[0].color == "purple" && renamed.spaces[0].icon == "eye", "the id stays")
        check(handle(.updateSpace, space: "nope", draft: SpaceDraft(name: "x")).reply.message.contains("No space"), "unknown space")
        check(handle(.deleteSpace, space: "Review").change == .removeSpace(id: "review", workspace: "work"), "delete")
        check(handle(.deleteSpace).reply.message == "space is required.", "delete needs a space")
        let session = agent(key: "topic:1", session: sessionA)
        let tagged = handle(.tagSession, session: sessionA, spaces: ["Review"], agents: [session])
        check(tagged.change == .tag(keys: ["topic:1"], spaces: ["review"]) && tagged.reply.message.contains("Review"), "tagged: \(tagged.reply.message)")
        check(handle(.tagSession, ticket: "ACME-1", spaces: [], agents: [session]).change == .tag(keys: ["topic:1"], spaces: []), "an empty list clears")
        check(handle(.tagSession, session: sessionB, spaces: ["review"], agents: [session]).reply.message.contains("No session"), "unknown session")
        check(handle(.tagSession, session: sessionA, spaces: ["nope"], agents: [session]).reply.message.contains("No space"), "unknown space for a session")
        var assistant = agent(key: "assistant:work:verifier", session: sessionB)
        assistant.kind = "assistant"
        check(handle(.tagSession, session: sessionB, spaces: ["review"], agents: [assistant]).reply.message.contains("role file"), "an assistant's spaces come from its file")
        check(handle(.tagSession, session: sessionA, agents: [session]).reply.ok == false, "spaces is required")
    }),

    ("workspace tools are write tools with the arguments they need, and send the request through the inbox", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let notices = MCPServer.NoticeSources(file: root.appendingPathComponent("n.json"), inbox: inbox, replyTimeout: 3, source: { NoticeSource(agent: nil, workspace: "work") })
        let tools = MCPServer.workspaceTools(sources: notices, workspaces: MCPServer.WorkspaceSource(file: { WorkspaceFile(workspaces: Workspaces.sample) }, environment: { nil }), now: { now })
        check(tools.map(\.name) == ["workspaces", "create_workspace", "update_workspace", "create_space", "update_space", "delete_space", "tag_session"], "\(tools.map(\.name))")
        check(tools.filter { !$0.readOnly }.map(\.name) == ["create_workspace", "update_workspace", "create_space", "update_space", "delete_space", "tag_session"], "only the changes write")
        check(tool("create_workspace", tools).required == ["name"] && tool("create_space", tools).required == ["name"] && tool("update_space", tools).required == ["space"] && tool("tag_session", tools).required == ["spaces"], "required")
        check(try tool("workspaces", tools).run([:]).contains("**Personal**"), "listing needs no app")
        let received = Inbox()
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if let name = ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).first(where: WorkspaceRequests.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)), let request = AgentInbox.decode(WorkspaceRequest.self, from: data) {
                    received.requests.append(data)
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    try? AgentInbox.encode(NoticeReply(id: request.id, ok: true, notice: "acme", message: "Created the workspace Acme, id acme."))
                        .write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let answer = try tool("create_workspace", tools).run(["name": "Acme", "roots": ["~/git/acme"], "jira_projects": "acme, isd", "slack": true])
        check(answer.hasPrefix("Created the workspace Acme"), answer)
        let sent = received.requests.first.flatMap { AgentInbox.decode(WorkspaceRequest.self, from: $0) }
        check(sent?.action == .createWorkspace && sent?.draft?.name == "Acme" && sent?.draft?.roots == ["~/git/acme"] && sent?.draft?.jiraProjects == ["acme", "isd"] && sent?.draft?.slack == true
              && sent?.source.workspace == "work", "\(String(describing: sent))")
        check((try? tool("create_workspace", tools).run(["name": "A", "color": "magenta"])) == nil, "a colour that is not offered")
        check((try? tool("tag_session", tools).run(["spaces": ["a"]])) == nil && (try? tool("tag_session", tools).run(["spaces": ["a"], "session_id": sessionA, "ticket": "ACME-1"])) == nil, "tag_session needs one target")
        check((try? tool("update_space", tools).run([:])) == nil, "update_space needs a space")
    }),

    ("open_in_app takes exactly one target, round trips as a worktime://open link and resolves against the agents", {
        let source = NoticeSource(session: "s1", cwd: "/x")
        func request(_ args: [String: Any]) throws -> OpenRequest { try OpenLinks.request(args, source: source, now: now, id: sessionB) }
        check(try request(["ticket": "acme-1"]).ticket == "ACME-1" && request(["pr_url": "acme-com/orbit.api#12"]).pullRequest == pr && request(["page": "jira"]).page == "jira", "targets")
        check((try? request([:])) == nil && (try? request(["ticket": "ACME-1", "page": "jira"])) == nil && (try? request(["page": "nowhere"])) == nil && (try? request(["ticket": "x"])) == nil
              && (try? request(["pr_url": "not a pr"])) == nil, "exactly one valid target")
        for target in [OpenTarget.agent("topic:1"), .ticket("ACME-1"), .pullRequest(pr), .page(.gitHub)] {
            check(OpenLinks.parse(OpenLinks.link(target)) == target, "\(OpenLinks.link(target))")
        }
        check(OpenLinks.parse("worktime://open?ticket=nope") == nil && OpenLinks.parse("worktime://open") == nil && OpenLinks.parse("https://open?ticket=ACME-1") == nil && OpenLinks.parse("worktime://pr?url=x") == nil, "other links")
        let agents = [agent()]
        check(OpenLinks.target(try request(["session_id": sessionA]), agents: agents) == .success(.agent("topic:1")), "a session to its agent")
        check(OpenLinks.target(try request(["session_id": sessionB]), agents: agents) == .failure(NoticeError("No session \(sessionB) in agents_overview.")), "unknown session")
        let ticketRequest = try request(["ticket": "ACME-1"]), pageRequest = try request(["page": "agent"])
        check(OpenLinks.target(ticketRequest, agents: []) == .success(.ticket("ACME-1")) && OpenLinks.target(pageRequest, agents: []) == .success(.page(.agent)), "ticket and page")
        let open = MCPServer.coordinatorTools().first { $0.name == "open_in_app" }
        check(open?.readOnly == false && open?.properties["page"]?["enum"] as? [String] == OpenLinks.pages, "listed with the pages")
        check(OpenLinks.requestName(sessionB) == "\(sessionB).open.json" && OpenLinks.isRequest(OpenLinks.requestName(sessionB)) && !AgentInbox.isRequest(OpenLinks.requestName(sessionB)), "its own inbox file")
    }),

    ("agents_overview takes a since filter on when the agent was last updated", {
        let filter = try AgentFilter(["since": "2027-01-14"], now: now)
        let early = agent(updated: Date(timeIntervalSince1970: 1_700_000_000)), late = agent(updated: now)
        check(!filter.matches(early) && filter.matches(late) && filter.applied.first?.hasPrefix("since") == true, "since: \(filter.applied)")
        check(AgentFilter.properties["since"] != nil && (try? AgentFilter(["since": "whenever"], now: now)) == nil, "listed, and checked")
        check(try AgentFilter(["since": "2027-01-14"], names: ["kind"], now: now).since == nil, "attention does not take it")
    }),

    ("the stdio layer declares listChanged and schema_version, lists the new tools and answers them over JSON-RPC", {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let s = sources(root)
        try write(PendingDecisions.encode([decision()], now: now), s.decisions)
        try write(AppInfos.encode(info()), s.appInfo)
        let server = MCPServer(tools: MCPServer.coordinatorTools(sources: s, now: { now }) + MCPServer.workspaceTools(), version: "9")
        let initialize = json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let result = initialize["result"] as? [String: Any] ?? [:]
        let tools = (result["capabilities"] as? [String: Any])?["tools"] as? [String: Any]
        check(tools?["listChanged"] as? Bool == true, "listChanged \(String(describing: tools))")
        let instructions = result["instructions"] as? String ?? ""
        check(instructions.contains("schema_version: \(MCPServer.schemaVersion)") && instructions.contains("reconnect") && instructions.contains("pending_decisions") && instructions.contains("agent Main"), instructions)
        let listing = json(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let listed = ((listing["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        check(listed.map { $0["name"] as? String ?? "" } == server.tools.map(\.name), "every tool is listed")
        for entry in listed {
            let schema = entry["inputSchema"] as? [String: Any] ?? [:]
            check(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false && (entry["annotations"] as? [String: Any])?["readOnlyHint"] is Bool, "\(entry["name"] ?? "") schema")
        }
        let pending = call(server, "pending_decisions")
        check(!pending.isError && pending.text.contains("Verifier asks to run Bash"), pending.text)
        check(call(server, "app_info").text.contains("pid 4242") && call(server, "request_status", #"{"request_id":"nope"}"#).isError, "tool results over the wire")
        check(call(server, "wait_for", "{}").isError, "invalid arguments are a tool error, not a crash")
        check(MCPServer.isInitialized(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) && !MCPServer.isInitialized(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#), "the client's initialized notice")
        check(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "no answer to a notice")
    }),

    ("a changed tool set is announced with tools/list_changed, a first run or an unchanged set is not", {
        let first = MCPServer.coordinatorTools()
        check(!ToolSets.changed(previous: nil, tools: first), "nothing saved: a first run")
        let saved = ToolSets.record(first, version: "1")
        check(!ToolSets.changed(previous: saved, tools: first), "the same tools")
        check(ToolSets.changed(previous: saved, tools: Array(first.dropLast())), "a tool was removed")
        check(ToolSets.changed(previous: saved, tools: first + MCPServer.workspaceTools()), "tools were added")
        check(ToolSets.changed(previous: Data("not json".utf8), tools: first), "an unreadable record counts as changed")
        check(ToolSets.digest(first) == ToolSets.digest(MCPServer.coordinatorTools()), "the digest is stable")
        let notice = json(ToolSets.changeNotice)
        check(notice["method"] as? String == "notifications/tools/list_changed" && notice["id"] == nil, "a notification, not a request")
    }),

    ("every tool of the server is documented in the plugin's skill and the README, and the new write tools ask", {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skills = repo.appendingPathComponent("plugin/skills")
        let documented = ((try? FileManager.default.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil)) ?? []).compactMap {
            try? String(contentsOf: $0.appendingPathComponent("SKILL.md"), encoding: .utf8)
        }.joined(separator: "\n")
        let readme = (try? String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
        check(!documented.isEmpty && !readme.isEmpty, "the docs were found at \(repo.path)")
        let missingSkill = MCPServer.toolNames.filter { !documented.contains("`\($0)`") }
        let missingReadme = MCPServer.toolNames.filter { !readme.contains("`\($0)`") }
        check(missingSkill.isEmpty, "not in the plugin skills: \(missingSkill)")
        check(missingReadme.isEmpty, "not in the README: \(missingReadme)")
        check(documented.contains("reconnect") && (try? String(contentsOf: repo.appendingPathComponent("plugin/README.md"), encoding: .utf8))?.contains("reconnect") == true, "the reconnect note")
        guard let builtIn = AgentBuiltIn.decode(try? Data(contentsOf: repo.appendingPathComponent("agent/src/\(AgentBuiltIn.fileName)"))) else { return check(false, "built-in list") }
        let asking = ["create_workspace", "update_workspace", "create_space", "update_space", "delete_space", "tag_session"].map { builtIn.mcpPrefix + $0 }
        check(asking.allSatisfy(builtIn.alwaysAsk.contains), "the workspace changes ask")
        let open = ["open_in_app", "pending_decisions", "request_status", "wait_for", "ticket_timeline", "outcomes", "app_info", "usage_summary", "events_since", "workspaces"].map { builtIn.mcpPrefix + $0 }
        check(open.allSatisfy { !builtIn.alwaysAsk.contains($0) }, "the reads and open_in_app do not")
        check(MCPServer.allTools.filter { !$0.readOnly }.map(\.name).filter { name in
            !builtIn.alwaysAsk.contains(builtIn.mcpPrefix + name) && !["notify", "cancel_notification", "add_reminder", "analyze_routine", "open_in_app"].contains(name)
        }.isEmpty, "every write tool asks, but the few that only touch WorkTime's own notices, reminders and window")
    }),
]
