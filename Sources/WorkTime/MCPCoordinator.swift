import Foundation

/// The tools that let a Claude Code session coordinate WorkTime: what waits for the user, a request's outcome, waiting for an agent, timelines,
/// outcomes, the app's own facts, usage, the event feed and navigating the app. They read files the app writes; the only write is open_in_app,
/// which only shows something. Nothing here answers a decision.
extension MCPServer {
    /// Bumped whenever a tool is added, removed or changes its arguments, so a client can tell its connection is out of date.
    static let schemaVersion = 2

    struct CoordinatorSources {
        var agentState = AppPaths.agentState
        var decisions = AppPaths.decisionState
        var timeline = AppPaths.timelineState
        var appInfo = AppPaths.appInfo
        var events = AppPaths.eventLog
        var usage = AppPaths.usageLog
        var inbox = AppPaths.agentInbox
        var workspaces = WorkspaceSource()
        var notices = NoticeSources()
        var alive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

        func agents() -> [AgentState] { (try? Data(contentsOf: agentState)).flatMap(AgentOverview.decode)?.agents ?? [] }

        func decisionFile() -> PendingDecisions.File? { PendingDecisions.decode(try? Data(contentsOf: decisions)) }

        func requestStatus(_ id: String, now: Date) -> RequestStatus? {
            let reply = (try? Data(contentsOf: inbox.appendingPathComponent(AgentInbox.replyName(id)))).flatMap { AgentInbox.decode(AgentInbox.Reply.self, from: $0) }
            let saved = (try? Data(contentsOf: inbox.appendingPathComponent(RequestStatuses.recordName(id)))).flatMap { AgentInbox.decode(AsyncRequest.self, from: $0) }
            let inInbox = FileManager.default.fileExists(atPath: inbox.appendingPathComponent(AgentInbox.requestName(id)).path)
            guard let record = saved ?? (reply != nil || inInbox ? AsyncRequest(id: id, created: now, target: "request", waitsForUser: false, deadline: now) : nil) else { return nil }
            return RequestStatuses.status(record, reply: reply, inInbox: inInbox, decisions: decisionFile()?.decisions ?? [], agents: agents(), now: now)
        }

        func record(_ id: String) -> AsyncRequest? {
            (try? Data(contentsOf: inbox.appendingPathComponent(RequestStatuses.recordName(id)))).flatMap { AgentInbox.decode(AsyncRequest.self, from: $0) }
        }
    }

    static func coordinatorTools(sources: CoordinatorSources = CoordinatorSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func uuid(_ args: [String: Any], _ name: String) throws -> String {
            guard let id = FilterLogic.text(args, name), ClaudeTranscripts.isSessionID(id) else { throw MCPToolError("\(name) must be the id send_to_agent gave.") }
            return id
        }
        return [
            MCPTool(name: "pending_decisions",
                    description: "Everything that waits for the user's own answer, oldest first: permission prompts (agent, tool, one-line input, age), reuse-or-new "
                        + "questions (ticket, role, preview), requests for a tool an assistant lacks, blocked turns, review drafts ready (pull request, verdict, number of comments), "
                        + "automation questions and urgent notifications, each with an id and the worktime:// link that opens it. READ-ONLY: no tool answers, approves, posts or "
                        + "allows any of these; only the user can, with their own click in the app. Use it to tell them what waits and where.",
                    properties: ["kind": ["type": "string", "enum": PendingDecision.Kind.allCases.map(\.rawValue), "description": "Only this kind."]]) { args in
                let kind = try FilterLogic.choice(args, "kind", allowed: PendingDecision.Kind.allCases.map(\.rawValue)).flatMap(PendingDecision.Kind.init)
                guard let file = sources.decisionFile() else { throw MCPToolError("WorkTime has not written its decisions yet (\(sources.decisions.path)). Open WorkTime.") }
                return FilterLogic.header(FilterLogic.applied(["kind": kind?.rawValue])) + PendingDecisions.markdown(file, now: now(), kind: kind)
            },
            MCPTool(name: "request_status",
                    description: "How a send_to_agent call made with async true went: pending (the app has not taken it, or the user has not answered the reuse-or-new question), answered "
                        + "(the user answered and the prompt is being delivered), created (a new session was made for it), started (the prompt started or queued in an existing session), "
                        + "timed_out (nobody answered in time; nothing was sent) or refused. With the session id and the resolved ticket or session once known. Read-only.",
                    properties: ["request_id": ["type": "string", "description": "The request_id send_to_agent returned."]], required: ["request_id"]) { args in
                let id = try uuid(args, "request_id")
                guard let status = sources.requestStatus(id, now: now()) else { throw MCPToolError("No request \(id). It may be older than a day, or never reached WorkTime.") }
                return RequestStatuses.markdown(status)
            },
            MCPTool(name: "wait_for",
                    description: "Waits (long poll, at most timeout_seconds, 600 at most) for an agent to change and returns its new state, with its last result when it finished. "
                        + "Name what to watch: session_id, request_id (the session an async send_to_agent made) or ticket (all its agents). until: idle (nothing working), "
                        + "finished (idle with a result), needs_you (waiting for permission, a question or an error) or any (any change); idle and finished also return when the agent needs the user, "
                        + "and the answer says why it returned (result: idle, finished, needs_you, changed, timed_out, refused). Read-only: it never answers a prompt for the user. "
                        + "Polling alternative: events_since.",
                    properties: ["session_id": ["type": "string", "description": "A session id from agents_overview or send_to_agent."],
                                 "request_id": ["type": "string", "description": "A request_id from send_to_agent with async true."],
                                 "ticket": ["type": "string", "description": "A Jira key like PROJ-123: every agent about it."],
                                 "until": ["type": "string", "enum": WaitUntil.allCases.map(\.rawValue), "description": "finished when left out."],
                                 "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": Int(WaitFor.maximum), "description": "\(Int(WaitFor.fallback)) when left out."]]) { args in
                let named = ["session_id", "request_id", "ticket"].filter { FilterLogic.text(args, $0) != nil }
                guard named.count == 1 else { throw MCPToolError("Give exactly one of session_id, request_id or ticket.") }
                let until = try FilterLogic.choice(args, "until", allowed: WaitUntil.allCases.map(\.rawValue)).flatMap(WaitUntil.init) ?? .finished
                var target = WaitTarget()
                switch named[0] {
                case "session_id": target.session = FilterLogic.text(args, "session_id")
                case "ticket":
                    guard let key = FilterLogic.text(args, "ticket").flatMap(JiraLogic.issueKey) else { throw MCPToolError("ticket must be a Jira key like PROJ-123.") }
                    target.ticket = key
                default:
                    let id = try uuid(args, "request_id")
                    guard sources.requestStatus(id, now: now()) != nil else { throw MCPToolError("No request \(id).") }
                    target.request = sources.record(id) ?? AsyncRequest(id: id, created: .distantPast, target: "", waitsForUser: false, deadline: .distantFuture)
                }
                let result = WaitFor.run(target, until: until, timeout: WaitFor.timeout(args["timeout_seconds"]), read: {
                    WaitSnapshot(agents: sources.agents(), decisions: sources.decisionFile()?.decisions ?? [],
                                 request: target.request.flatMap { sources.requestStatus($0.id, now: now()) })
                }, sleep: sources.sleep, now: now)
                return WaitFor.markdown(result, now: now())
            },
            MCPTool(name: "ticket_timeline",
                    description: "What happened for one ticket or pull request across all its sessions, oldest first, as WorkTime's Timeline shows it: what triggered the work, what Main asked, "
                        + "verdicts (PASS, FAIL, BLOCKED, Recommendation), drafted and posted reviews, the user's answers and the replies that ended a turn, with times. Read from a snapshot "
                        + "the app keeps for the most recent groups (a few weeks of work), not from transcripts. Read-only.",
                    properties: ["ticket": ["type": "string", "description": "A Jira key like PROJ-123."],
                                 "pr_url": ["type": "string", "description": "A GitHub pull request address; the ticket's group when it belongs to one."],
                                 "limit": ["type": "integer", "minimum": 1, "maximum": TimelineSnapshots.eventLimit, "description": "The newest this many events, \(TimelineSnapshots.eventLimit) when left out."]]) { args in
                let (ticket, pr) = (FilterLogic.text(args, "ticket"), FilterLogic.text(args, "pr_url"))
                guard (ticket == nil) != (pr == nil) else { throw MCPToolError("Give exactly one of ticket or pr_url.") }
                let key = try ticket.map { text in
                    guard let key = JiraLogic.issueKey(text) else { throw MCPToolError("ticket must be a Jira key like PROJ-123.") }
                    return key
                }
                let url = try pr.map { text in
                    guard let target = GitHubLink.pasted(text) else { throw MCPToolError("pr_url must be a GitHub pull request address.") }
                    return target.url
                }
                guard let file = TimelineSnapshots.decode(try? Data(contentsOf: sources.timeline)) else {
                    throw MCPToolError("WorkTime has not written its timelines yet (\(sources.timeline.path)). Open WorkTime.")
                }
                guard let group = TimelineSnapshots.find(ticket: key, pullRequest: url, in: file.groups) else {
                    return "No timeline for \(key ?? url ?? ""). The app keeps the \(TimelineSnapshots.groupLimit) most recently active tickets and pull requests with a session.\n"
                }
                return TimelineSnapshots.markdown(group, now: now(), limit: min(max(count(args["limit"], fallback: TimelineSnapshots.eventLimit, maximum: TimelineSnapshots.eventLimit), 1), TimelineSnapshots.eventLimit))
            },
            MCPTool(name: "outcomes",
                    description: "A compact table of the latest outcome per ticket or pull request: PASS, FAIL, BLOCKED or the Recommendation of its latest session, who gave it and when, newest first. "
                        + "Optional filters, all combined: ticket, space (a space of the workspace, by id or name), since (a date, ISO 8601 or HH:mm); the answer says which applied. Read-only.",
                    properties: ["ticket": ["type": "string", "description": "A Jira key like PROJ-123."],
                                 "space": ["type": "string", "description": "A space (lane) by id or name."],
                                 "since": ["type": "string", "description": "Only outcomes at or after this: YYYY-MM-DD, ISO 8601 or HH:mm."]]) { args in
                guard let file = TimelineSnapshots.decode(try? Data(contentsOf: sources.timeline)) else {
                    throw MCPToolError("WorkTime has not written its timelines yet (\(sources.timeline.path)). Open WorkTime.")
                }
                let date = now()
                let ticket = try FilterLogic.text(args, "ticket").map { text in
                    guard let key = JiraLogic.issueKey(text) else { throw MCPToolError("ticket must be a Jira key like PROJ-123.") }
                    return key
                }
                let since = try FilterLogic.bound(args, "since", end: false, now: date)
                var space: String?
                if let text = FilterLogic.text(args, "space") {
                    switch Spaces.resolve(text, in: sources.workspaces.file().workspaces.flatMap(\.spaces)) {
                    case .success(let found): space = found.id
                    case .failure(let error): throw MCPToolError(error.message)
                    }
                }
                return FilterLogic.header(FilterLogic.applied(["ticket": ticket, "space": space, "since": since]))
                    + TimelineSnapshots.outcomes(file.groups, ticket: ticket, space: space, since: since, now: date)
            },
            MCPTool(name: "app_info",
                    description: "WorkTime itself: version, git commit (or build date), process id, when it started and how long it has run, the data folder, workspaces and their spaces, "
                        + "how many sessions are working and waiting, whether the agent sidecar is built, the plan's usage windows when the app has them cached, and whether restarting "
                        + "the app now would interrupt running work (with the working sessions listed). Also says when this MCP connection is older than the app. Read-only.",
                    properties: [:]) { _ in
                guard let info = AppInfos.decode(try? Data(contentsOf: sources.appInfo)) else {
                    throw MCPToolError("WorkTime has not written its state yet (\(sources.appInfo.path)). Open WorkTime (an older version does not write it).")
                }
                return AppInfos.markdown(info, now: now(), alive: sources.alive(info.pid), mcpSchema: schemaVersion)
            },
            MCPTool(name: "usage_summary",
                    description: "What Claude calls cost, from WorkTime's usage log: totals and a table grouped by workspace, agent, routine, automation or model, dearest first. "
                        + "Costs are what Claude Code reported (an estimate, not a bill, in US dollars); calls without a reported cost are counted as unpriced. Adds the plan's windows when the app has them cached. Read-only.",
                    properties: ["range": ["type": "string", "enum": UsageRanges.names, "description": "today, 7d or 30d; today when left out."],
                                 "group_by": ["type": "string", "enum": UsageGroup.allCases.map(\.rawValue), "description": "workspace when left out."]]) { args in
                let range = try FilterLogic.choice(args, "range", allowed: UsageRanges.names).flatMap(UsageRanges.range) ?? .today
                let group = try FilterLogic.choice(args, "group_by", allowed: UsageGroup.allCases.map(\.rawValue)).flatMap(UsageGroup.init) ?? .workspace
                let date = now()
                let records = Usage.records(UsageLog(url: sources.usage).read(now: date), in: range, now: date)
                let info = AppInfos.decode(try? Data(contentsOf: sources.appInfo))
                return UsageRanges.markdown(records, range: range, group: group, plan: info?.plan, fetched: info?.planFetched, now: date)
            },
            MCPTool(name: "open_in_app",
                    description: "Brings the WorkTime window to the front on one item: a session (session_id), a ticket's page (ticket), a pull request (pr_url) or a page (page). "
                        + "It only navigates, changes nothing and asks nothing. Give exactly one.",
                    properties: ["session_id": ["type": "string", "description": "A session id from agents_overview."],
                                 "ticket": ["type": "string", "description": "A Jira key like PROJ-123: opens its page with the timeline."],
                                 "pr_url": ["type": "string", "description": "A GitHub pull request address."],
                                 "page": ["type": "string", "enum": OpenLinks.pages, "description": "A page of the main window."]], readOnly: false) { args in
                let request = try OpenLinks.request(args, source: sources.notices.source(), now: now())
                return try sources.notices.ask(AgentInbox.encode(request), id: request.id, name: OpenLinks.requestName(request.id), what: "the request").message
            },
            MCPTool(name: "events_since",
                    description: "A feed of what happens in WorkTime that a coordinator may react to: session started, finished, errored or waiting, decision raised or answered, review posted, "
                        + "automation fired, routine ran, app restarted. Each event has an increasing id. Without cursor it returns the newest cursor and the last \(AppEvents.latestCount) events; "
                        + "pass that cursor back to get only what came after (the answer gives the next cursor). The polling alternative to wait_for. Read-only.",
                    properties: ["cursor": ["type": "integer", "minimum": 0, "description": "The cursor an earlier call returned."],
                                 "limit": ["type": "integer", "minimum": 1, "maximum": AppEvents.pageLimit, "description": "At most this many events after the cursor, \(AppEvents.pageLimit) when left out."]]) { args in
                let cursor = number(args["cursor"]).map { Int($0) }
                let file = AppEvents.decode(try? Data(contentsOf: sources.events))
                let page = AppEvents.since(cursor, limit: count(args["limit"], fallback: AppEvents.pageLimit, maximum: AppEvents.pageLimit), in: file)
                return AppEvents.markdown(page.events, cursor: page.cursor, first: cursor == nil)
            },
        ]
    }

    static func count(_ value: Any?, fallback: Int, maximum: Int) -> Int {
        min(max(Int(number(value) ?? Double(fallback)), 1), maximum)
    }
}

/// `usage_summary`'s ranges and the table it prints.
enum UsageRanges {
    static let names = ["today", "7d", "30d"]

    static func range(_ name: String) -> UsageRange? {
        switch name {
        case "today": .today
        case "7d": .week
        case "30d": .month
        default: nil
        }
    }

    static func money(_ cost: Double) -> String { String(format: "$%.2f", cost) }

    static func markdown(_ records: [UsageRecord], range: UsageRange, group: UsageGroup, plan: [AppInfo.PlanWindow]?, fetched: Date?, now: Date) -> String {
        let summary = Usage.summary(records)
        var lines = ["Usage \(range.title.lowercased()) (estimate from Claude Code, not a bill): \(money(summary.cost)), \(UsageFormat.tokens(summary.tokens)) tokens, \(summary.runs) call\(summary.runs == 1 ? "" : "s")"
                     + (summary.unpriced > 0 ? ", \(summary.unpriced) without a reported cost" : "")]
        let rows = Usage.rows(records, by: group)
        if rows.isEmpty {
            lines.append("Nothing to group by \(group.rawValue) in this range.")
        } else {
            lines += ["", "| \(group.title) | Cost | Tokens | Calls | Models |", "| --- | --- | --- | --- | --- |"]
            lines += rows.map { "| \($0.name.replacingOccurrences(of: "|", with: "/")) | \(money($0.cost)) | \(UsageFormat.tokens($0.tokens)) | \($0.runs) | \($0.models.prefix(3).joined(separator: ", ")) |" }
        }
        if let plan, !plan.isEmpty {
            lines.append("")
            lines.append("Plan windows" + (fetched.map { " (read \(ClaudePlugin.ago($0, now: now)))" } ?? "") + ": "
                         + plan.map { "\($0.title) \(Int($0.percent))%" + ($0.resets.map { ", \(UsagePlan.resetText($0, now: now))" } ?? "") }.joined(separator: "; "))
        } else {
            lines.append("")
            lines.append("The plan's windows are not cached; they are read when the Usage page in WorkTime is open.")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
