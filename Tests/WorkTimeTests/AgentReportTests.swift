import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let routineKey = "routine:3F2504E0-4F89-41D3-9A0C-0305E82C3301"

private func workspace(_ id: String, _ name: String) -> Workspace {
    Workspace(id: id, name: name, symbol: "briefcase.fill", color: "blue", roots: [], githubOwners: [], jiraProjects: [], slack: nil, extraFiles: [])
}

private let workspaces = [workspace("work", "Work"), workspace("reviews", "Reviews")]

private func request(_ text: String = "Review done: request changes.", workspace: String? = nil, title: String? = nil, agent: String? = "assistant:work:reviewer",
                     caller: String? = "work", created: Date = now) -> ReportRequest {
    ReportRequest(id: UUID().uuidString, workspace: workspace, title: title, text: text,
                  source: NoticeSource(agent: agent, workspace: caller, session: nil, cwd: nil), created: created)
}

private func decide(_ request: ReportRequest, queued: [String] = [], ledger: AgentReports.Ledger = AgentReports.Ledger(), at date: Date = now) -> ReportDecision {
    AgentReports.decide(request, workspaces: workspaces, titles: ["assistant:work:reviewer": "Reviewer", routineKey: "Morning brief"], queued: { _ in queued }, ledger: ledger, now: date)
}

let agentReportTests: [(name: String, run: () throws -> Void)] = [
    ("reports: the prompt names the sender and parses back, and other prompts are not reports", {
        let prompt = AgentReports.prompt(from: "Reviewer", title: "Done", text: "Two blockers.")
        check(prompt == "Report from Reviewer: Done\nTwo blockers.", prompt)
        let parsed = AgentReports.parse(prompt)
        check(parsed?.from == "Reviewer" && parsed?.text == "Done\nTwo blockers.", "\(String(describing: parsed))")
        check(AgentReports.parse("From Main: hello") == nil && AgentReports.parse("Report from") == nil && AgentReports.parse("Report from a\nb: c") == nil, "not reports")
        check(AgentReports.prompt(from: "Reviewer", title: "  ", text: "x") == "Report from Reviewer: x", "an empty title is left out")
        check(AgentInbox.fromMain(prompt) == nil, "a report is not from Main")
    }),

    ("reports: the workspace is the one named, by id or name, else the caller's own", {
        func id(_ argument: String?, caller: String?) -> String? { try? AgentReports.target(argument: argument, caller: caller, in: workspaces).get().id }
        check(id(nil, caller: "work") == "work" && id("", caller: "reviews") == "reviews", "the caller's own")
        check(id("reviews", caller: "work") == "reviews" && id(" Reviews ", caller: "work") == "reviews", "by id or name")
        check(id(nil, caller: nil) == nil, "outside an agent a workspace is needed")
        check(id("all", caller: "work") == nil && id("nowhere", caller: "work") == nil && id(nil, caller: "gone") == nil, "unknown ones are refused")
    }),

    ("reports: a Main cannot report to itself, and the name carries the agent's title and a routine's mark", {
        var main = NoticeSource(agent: Workspaces.mainKey("work"), workspace: "work", session: nil, cwd: nil)
        check(AgentReports.isSelf(main, workspace: "work") && !AgentReports.isSelf(main, workspace: "reviews"), "own Main only")
        if case .reject(let why) = decide(ReportRequest(id: "1", workspace: nil, title: nil, text: "hi", source: main, created: now)) { check(why.contains("Main of Work"), why) } else { check(false, "refused") }
        main.workspace = "reviews"
        check(decide(ReportRequest(id: "1", workspace: "work", title: nil, text: "hi", source: main, created: now)) != .reject(""), "another workspace's Main is fine")
        let titles = ["assistant:work:reviewer": "Reviewer", routineKey: "Morning brief"]
        check(AgentReports.name(of: NoticeSource(agent: "assistant:work:reviewer", workspace: "work", session: nil, cwd: nil), titles: titles) == "Reviewer", "assistant")
        check(AgentReports.name(of: NoticeSource(agent: routineKey, workspace: "work", session: nil, cwd: nil), titles: titles) == "Morning brief (routine)", "routine")
        check(AgentReports.name(of: NoticeSource(agent: nil, workspace: nil, session: "s", cwd: "/repo/orbit"), titles: titles) == "Claude Code \u{00B7} orbit", "a Claude Code session")
    }),

    ("reports: a good request is delivered with a labelled prompt, a bad one is turned away", {
        guard case .deliver(let id, let name, let prompt) = decide(request(title: "Reviewed #12")) else { return check(false, "delivered") }
        check(id == "work" && name == "Reviewer" && prompt == "Report from Reviewer: Reviewed #12\nReview done: request changes.", "\(id) \(name) \(prompt)")
        guard case .deliver(let other, _, _) = decide(request(workspace: "reviews")) else { return check(false, "delivered elsewhere") }
        check(other == "reviews", "the named workspace")
        for bad in [request(""), request(String(repeating: "x", count: AgentReports.textLimit + 1)), request(created: now.addingTimeInterval(-600))] {
            if case .reject = decide(bad) { continue }
            check(false, "\(bad.text.prefix(20)) turned away")
        }
    }),

    ("reports: a routine's report is labelled as one", {
        guard case .deliver(_, let name, let prompt) = decide(request(agent: routineKey)) else { return check(false, "delivered") }
        check(name == "Morning brief (routine)" && prompt.hasPrefix("Report from Morning brief (routine): "), prompt)
    }),

    ("reports: six an hour, two waiting at a time, and the same text twice in ten minutes is dropped", {
        var ledger = AgentReports.Ledger()
        let caller = "assistant:work:reviewer"
        for index in 0..<5 { ledger.record(caller: caller, text: "report \(index)", now: now.addingTimeInterval(Double(index))) }
        check(ledger.problem(caller: caller, text: "another", pending: 0, now: now.addingTimeInterval(10)) == nil, "five sent, a sixth is fine")
        ledger.record(caller: caller, text: "report 5", now: now.addingTimeInterval(6))
        if case .refused(let why)? = ledger.problem(caller: caller, text: "seventh", pending: 0, now: now.addingTimeInterval(10)) { check(why.contains("limit is 6"), why) } else { check(false, "the limit") }
        check(ledger.problem(caller: caller, text: "seventh", pending: 0, now: now.addingTimeInterval(3601)) == nil, "an hour later it is free again")
        check(ledger.problem(caller: "assistant:work:developer", text: "seventh", pending: 0, now: now.addingTimeInterval(10)) == nil, "another agent has its own count")
        check(ledger.problem(caller: caller, text: "  Report   5 ", pending: 0, now: now.addingTimeInterval(20)) == .duplicate, "the same text, spaces and case aside")
        check(ledger.problem(caller: caller, text: "report 5", pending: 0, now: now.addingTimeInterval(700)) != .duplicate, "after ten minutes it may repeat")
        var fresh = AgentReports.Ledger()
        fresh.record(caller: caller, text: "a", now: now)
        if case .refused(let why)? = fresh.problem(caller: caller, text: "b", pending: 2, now: now) { check(why.contains("2 of your reports"), why) } else { check(false, "pending limit") }
        let queued = [AgentReports.prompt(from: "Reviewer", title: nil, text: "a"), "From Main: x", AgentReports.prompt(from: "Developer", title: nil, text: "b"), AgentReports.prompt(from: "Reviewer", title: nil, text: "c")]
        check(AgentReports.pending(queued: queued, from: "Reviewer") == 2, "counts its own queued reports")
        if case .reject(let why) = decide(request("fresh"), queued: queued) { check(why.contains("waiting in Main's queue"), why) } else { check(false, "two waiting are enough") }
    }),

    ("reports: Main starts on a report when idle, queues it while busy or waiting, and turns it away when the queue is full", {
        check(AgentReports.route(busy: false, queued: 0) == .start, "idle")
        check(AgentReports.route(busy: true, queued: 0) == .queue && AgentReports.route(busy: false, queued: 1) == .queue, "busy or behind others")
        if case .reject = AgentReports.route(busy: true, queued: AgentInbox.queueLimit) { } else { check(false, "full") }
        check(AgentReports.replyText(.queue, workspace: "work").contains("Queued") && AgentReports.replyText(.start, workspace: "work").contains("reading"), "reply texts")
    }),

    ("reports: Main is told reports are information and every agent how to send one", {
        check(AgentLogic.mainBasePrompt.contains("Report from") && AgentLogic.mainBasePrompt.contains("never the user speaking"), "Main's prompt")
        check(AgentReports.mainNote.contains("approval") && AgentReports.agentNote.contains("send_to_main"), "notes")
        check(AgentSessions.title(prompt: AgentReports.prompt(from: "Reviewer", title: nil, text: "Done.")) == "From Reviewer: Done.", "the session is named after the report")
    }),

    ("reports: the tool is in the server, asks by default, may be allowed for a scheduled run by the user, and goes through the inbox", {
        check(MCPServer.toolNames.contains("send_to_main"), "listed")
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent/src/\(AgentBuiltIn.fileName)")
        guard let builtIn = AgentBuiltIn.decode(try? Data(contentsOf: file)) else { return check(false, "decodes") }
        let tool = AgentReports.tool
        check(builtIn.alwaysAsk.contains(tool) && !(builtIn.alwaysAskRisky ?? []).contains(tool) && builtIn.unattendedAllowed == [tool], "ask, not risky, unattended allowed")
        let rules = [AgentRules.dontAsk(tool), AgentRules.dontAsk("mcp__worktime__create_routine")]
        check(AgentRules.sent(rules, unattended: true, builtIn: builtIn) == [AgentRules.dontAsk(tool)], "an unattended run keeps only this opt-in")
        check(AgentRules.sent(rules, unattended: false, builtIn: builtIn) == rules, "an attended agent keeps them all")
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        var sources = MCPServer.NoticeSources()
        sources.inbox = inbox
        sources.replyTimeout = 0.5
        sources.source = { NoticeSource(agent: "assistant:work:reviewer", workspace: "work", session: nil, cwd: nil) }
        let send = MCPServer.reportTools(sources: sources, now: { now })[0]
        check((try? send.run(["text": " "])) == nil && !send.readOnly, "text is required and the tool acts")
        let timedOut = Result { try send.run(["text": "Done", "workspace": "reviews", "title": "Reviewed"]) }
        check({ if case .failure(let error) = timedOut { return "\(error)".contains("did not take") }; return false }(), "the app did not answer: \(timedOut)")
    }),
]
