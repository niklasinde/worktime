import Foundation

/// The agent tools of the MCP server: the overview the app writes, session transcripts, what needs the user across the
/// sources the `--mcp` process can read on its own, and handing a prompt to a pull request's agent in the running app.
extension MCPServer {
    /// The workspaces the app saved and the one the calling Main belongs to (`WORKTIME_WORKSPACE`), which tools default to.
    struct WorkspaceSource {
        var file: () -> WorkspaceFile = { Workspaces.decode(try? Data(contentsOf: AppPaths.workspaceFile)) }
        var environment: () -> String? = { ProcessInfo.processInfo.environment[Workspaces.envKey] }

        func scope(_ args: [String: Any]) throws -> WorkspaceScope {
            switch Workspaces.scope(argument: args["workspace"], environment: environment(), in: file().workspaces) {
            case .success(let scope): return scope
            case .failure(let error): throw MCPToolError(error.message)
            }
        }
    }

    static let workspaceProperty: [String: Any] = [
        "type": "string",
        "description": "A workspace id or name, or all. Left out, the calling Main's own workspace, or all outside a Main.",
    ]

    struct AgentSources {
        var stateFile = AppPaths.agentState
        var inbox = AppPaths.agentInbox
        var projects = ClaudeTranscripts.projectsFolder
        var topics = AppPaths.topicAgents
        var assistants = AssistantFiles()
        var workspaces = WorkspaceSource()
        var notices = NoticeSources()
        var replyTimeout: TimeInterval = 10
        /// Starts reading Slack mentions and unread DMs (true: Slack alone was asked for) and returns what waits for them as Markdown, nil when Slack is not signed in.
        var slack: (Bool) -> () -> String? = { MCPServer.slackAttention(explicit: $0) }

        func agents() -> [AgentState] { (try? Data(contentsOf: stateFile)).flatMap(AgentOverview.decode)?.agents ?? [] }

        func assistantEntries(_ args: [String: Any]) throws -> [AssistantEntry] {
            let scope = try workspaces.scope(args)
            return workspaces.file().workspaces.filter { Workspaces.includes($0.id, in: scope) }.flatMap { workspace in
                assistants.list(workspace.id).map { AssistantEntry(workspace: workspace.id, role: $0) }
            }
        }

        /// The agent `agent` or `pr_url` names: an assistant, a pull request or a topic, nil when neither is given.
        func target(_ args: [String: Any]) throws -> AgentTarget? {
            guard let text = [args["agent"], args["pr_url"]].compactMap({ $0 as? String })
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            switch Assistants.resolve(text, in: try assistantEntries(args)) {
            case .success(let target)?: return target
            case .failure(let error)?: throw MCPToolError(error.message)
            case nil: break
            }
            switch TopicAgents.resolve(text, topics: TopicAgents.decode(try? Data(contentsOf: topics))) {
            case .success(let target): return target
            case .failure(let error): throw MCPToolError(error.message)
            }
        }

        func workspace(of target: AgentTarget, in agents: [AgentState]) -> String? {
            if let id = Assistants.parse(key: target.key)?.workspace { return id }
            if let state = agents.first(where: { $0.key == target.key }) { return state.workspace }
            let saved = workspaces.file()
            return GitHubLink.pullRequest(at: target.key) != nil
                ? Workspaces.assign(Workspaces.prSubject(target.key, override: saved.overrides[target.key]), in: saved.workspaces) : nil
        }

        var allSpaces: [Space] { workspaces.file().workspaces.flatMap(\.spaces) }

        /// The id of the space `space` names among the spaces of the target's workspace, nil when the call names none.
        func space(_ args: [String: Any], target: AgentTarget, agents: [AgentState]) throws -> String? {
            guard let text = FilterLogic.text(args, "space") else { return nil }
            let spaces = Workspaces.workspace(workspace(of: target, in: agents), in: workspaces.file().workspaces)?.spaces ?? []
            switch Spaces.resolve(text, in: spaces) {
            case .success(let found): return found.id
            case .failure(let error): throw MCPToolError(error.message)
            }
        }

        func checkDelegation(_ target: AgentTarget, args: [String: Any], agents: [AgentState]) throws {
            let scope = try workspaces.scope(args)
            let all = workspaces.file().workspaces
            let claimedBy = GitHubLink.pullRequest(at: target.key).map {
                Workspaces.claimants(owner: $0.repo.split(separator: "/").first.map(String.init),
                                     folder: agents.first { $0.key == target.key }?.folder, in: all)
            } ?? []
            if let problem = Workspaces.delegationProblem(target: workspace(of: target, in: agents), scope: scope,
                                                         workspaces: all, claimedBy: claimedBy) {
                throw MCPToolError(problem)
            }
        }

        /// The agent a Main of `workspace` would send to with these arguments, as send_to_agent resolves it; nil when it is
        /// unclear, belongs to another workspace or the call names a workspace itself.
        func delegation(_ args: [String: Any], from workspace: String) -> AgentTarget? {
            var sources = self
            sources.workspaces.environment = { workspace }
            guard (args["workspace"] as? String)?.trimmingCharacters(in: .whitespaces).isEmpty ?? true,
                  let target = try? sources.target(args), (try? sources.checkDelegation(target, args: args, agents: sources.agents())) != nil else { return nil }
            return GitHubLink.pullRequest(at: target.key).map { AgentTarget(key: $0.url, title: target.title) } ?? target
        }
    }

    static let attentionSections = ["pull_requests", "agents", "notifications", "slack", "meetings"]

    static let agentProperty: [String: Any] = ["type": "string",
                                               "description": "A pull request url, a topic agent's key (topic:<id>) or name, or an assistant's role name or key, as agents_overview lists them; Main (with workspace) for a workspace's Main."]

    static func agentTools(_ opened: Result<MeetingStore, Error>, sources: AgentSources = AgentSources(),
                           github: [MCPTool] = [], now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func stateFile() throws -> AgentOverview.File {
            guard let data = try? Data(contentsOf: sources.stateFile) else {
                throw MCPToolError("WorkTime has not written its agents yet (\(sources.stateFile.path)). Open WorkTime.")
            }
            guard let file = AgentOverview.decode(data) else { throw MCPToolError("\(sources.stateFile.path) could not be read.") }
            return file
        }
        func scoped(_ args: [String: Any]) throws -> (scope: WorkspaceScope, file: AgentOverview.File) {
            var file = try stateFile()
            let scope = try sources.workspaces.scope(args)
            file.agents = Workspaces.filter(file.agents, in: scope)
            return (scope, file)
        }
        return [
            MCPTool(name: "agents_overview",
                    description: "Lists the WorkTime agents (Main, its assistants, one per pull request and the topic agents), most urgent first: waiting for the "
                        + "user's permission (with the tool it asks for), finished with a result the user has not seen, errored, working, "
                        + "idle. Each with its pull request url, worktime://agent link, folder, session id, last prompt and last result. An assistant's session "
                        + "for a Jira ticket shows as a ticket session with its role and ticket; ticket lists every agent about one ticket, so look there before "
                        + "sending work for it.",
                    properties: ["active_only": ["type": "boolean", "description": "Leave out idle agents. False when left out."],
                                 "workspace": workspaceProperty].merging(AgentFilter.properties) { $1 }) { args in
                let filter = try AgentFilter(args, spaces: sources.allSpaces)
                var file = try scoped(args).file
                file.agents = file.agents.filter(filter.matches)
                return FilterLogic.header(filter.applied)
                    + AgentOverview.markdown(file, now: now(), active: args["active_only"] as? Bool ?? false, spaces: sources.allSpaces)
            },
            MCPTool(name: "agent_session",
                    description: "A compact transcript of one agent's Claude Code session: the user's prompts, the assistant's replies, "
                        + "tool calls in one line each and the final result, without thinking or tool output. Newest kept when cut. For Codex agents, use agents_overview for the last prompt and result, or wait_for to watch a run.",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "The pull request whose agent to read; the same as agent."],
                                 "workspace": workspaceProperty,
                                 "session_id": ["type": "string", "description": "A session id from agents_overview, instead of agent."],
                                 "max_chars": ["type": "integer", "minimum": 1000, "maximum": outputLimit,
                                               "description": "Keep at most this many characters, \(AgentTranscript.defaultLimit) when left out."]]) { args in
                var session = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespaces)
                var cwd: String?
                let agents = (try? stateFile())?.agents ?? []
                if let target = try sources.target(args) {
                    guard let agent = agents.first(where: { $0.key == target.key }) else {
                        throw MCPToolError("No agent for \(target.title) in agents_overview.")
                    }
                    try sources.checkDelegation(target, args: args, agents: agents)
                    guard let id = agent.sessionID else { throw MCPToolError("The agent \(target.title) has no session yet.") }
                    session = id
                    cwd = agent.folder
                } else if let id = session {
                    cwd = agents.first { $0.sessionID == id }?.folder
                }
                guard let session, !session.isEmpty else { throw MCPToolError("agent or session_id is required.") }
                guard let url = AgentTranscript.url(sessionID: session, cwd: cwd, root: sources.projects),
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw MCPToolError("No transcript for session \(session).")
                }
                let limit = min(max(Int(number(args["max_chars"]) ?? Double(AgentTranscript.defaultLimit)), 1000), outputLimit)
                return "Session \(session)\n\n" + AgentTranscript.compact(jsonl: text, maxChars: limit)
            },
            MCPTool(name: "attention",
                    description: "What needs the user right now, in one place: pull requests waiting on them, agents waiting for permission "
                        + "or with unseen results, Slack mentions they have not answered, read or dismissed and unread DMs (when signed in), and open action items from the last "
                        + "two weeks of meetings. Start here for \u{201C}what do I need to look at\u{201D}. Optional filters: section "
                        + "limits it to one of those parts, kind and status narrow its agents; the answer says which applied.",
                    properties: ["workspace": workspaceProperty,
                                 "section": ["type": "string", "enum": attentionSections, "description": "Only this part."],
                                 "kind": AgentFilter.properties["kind"]!, "status": AgentFilter.properties["status"]!]) { args in
                let scope = try sources.workspaces.scope(args)
                let workspaces = sources.workspaces.file().workspaces
                let only = try FilterLogic.choice(args, "section", allowed: attentionSections)
                let filter = try AgentFilter(args, names: ["kind", "status"])
                func wanted(_ section: String) -> Bool { only == nil || only == section }
                let slack = wanted("slack") && (scope.id == nil || Workspaces.workspace(scope.id, in: workspaces)?.slack != nil)
                    ? sources.slack(only == "slack") : nil
                var sections: [String] = []
                if wanted("pull_requests"), let tool = github.first(where: { $0.name == "github_needs_attention" }) {
                    sections.append("## Pull requests\n" + ((try? tool.run(["limit": 8, "workspace": scope.id ?? Workspaces.allChoice]))
                                                            ?? "The GitHub cache could not be read.\n"))
                }
                if wanted("agents") {
                    sections.append("## Agents\n" + ((try? scoped(args).file).map { file in
                        var file = file
                        file.agents = file.agents.filter(filter.matches)
                        return AgentOverview.markdown(file, now: now(), active: true, limit: 10, spaces: sources.allSpaces)
                    } ?? "WorkTime has not written its agents yet.\n"))
                }
                if wanted("notifications"), let notices = noticeAttention(sources.notices) { sections.append("## Notifications from agents\n" + notices) }
                if let text = slack?() { sections.append("## Slack\n" + text) }
                if wanted("meetings"), let items = try? openedStore(opened).openActionItems(limit: 10, since: TodoLogic.meetingCutoff(now: now())) {
                    sections.append("## Meeting action items (not tied to a workspace)\n" + (items.isEmpty ? "None open.\n" : items.map {
                        "- \(ActivityLogic.dateText($0.date)) \u{00B7} \($0.title) (meeting id \($0.meeting)) \u{00B7} "
                            + ($0.owner.map { "\($0): " } ?? "") + $0.task
                    }.joined(separator: "\n") + "\n"))
                }
                return cut(FilterLogic.header(FilterLogic.applied(["section": only]) + filter.applied) + sections.joined(separator: "\n"), at: outputLimit)
            },
            MCPTool(name: "send_to_agent",
                    description: "Delivers one prompt to a WorkTime agent. For a handoff to an existing chat, find it with agents_overview and send the context and next step yourself. "
                        + "For an existing topic or ticket session, use its exact topic:<id> key as agent. For an assistant's own chat, use its assistant key. "
                        + "For a new assignment to a role, pass agent (the assistant's role name) with ticket or pr_url. One call per ticket. "
                        + "Use pr_url alone for a PR's own agent, or pr_urls for one agent covering several PRs. Pass known subject links in links. "
                        + "WorkTime can ask the user to choose an existing linked agent or create one. Use new_session only when the user requests a fresh role session. "
                        + "An idle agent starts the prompt, a busy agent queues it, and a permission wait can refuse it. "
                        + "With async true, check the returned request_id with request_status. Use wait_for for the receiving agent's result. "
                        + "To message a workspace's Main from outside it, set agent to Main and specify workspace when needed. Main returns a direct acknowledgement "
                        + "and applies send_to_main limits (\(AgentReports.hourlyLimit) per hour and \(AgentReports.pendingLimit) waiting per caller).",
                    properties: ["agent": agentProperty,
                                 "pr_url": ["type": "string", "description": "Alone: talks to that pull request's own agent. With an assistant as agent and no ticket: "
                                     + "the pull request the assistant's session is for (not the pull request's own agent)."],
                                 "links": ["type": "array", "items": ["type": "string"], "description": "Links to attach to the receiving agent. Pass each known Jira key, GitHub pull request URL, Slack thread URL, or kind:id here when delegating work."],
                                 "pr_urls": ["type": "array", "items": ["type": "string"], "maxItems": PullRequestSets.limit,
                                             "description": "Two or more pull requests' GitHub urls for ONE agent that works on them together as a set "
                                                 + "(made when there is none, and the pull requests stay in it): a reviewer's cross-pull-request check, or a change that spans repositories."],
                                 "ticket": ["type": "string", "description": "A Jira ticket key like PROJ-123, always together with agent set to an assistant's role (like Verifier): "
                                     + "its session for this ticket gets the prompt. One ticket per call. Must be in the workspace's Jira projects."],
                                 "new_session": ["type": "boolean", "description": "With an assistant and ticket or pr_url: start a new session even when the assistant has one for the "
                                     + "subject. False when left out."],
                                 "async": ["type": "boolean", "description": "Return at once with a request_id and the current state instead of waiting for the app and for the user's "
                                     + "answer to the reuse-or-new question (which can take up to the user's setting, 30 minutes by default). Read the outcome with request_status or wait_for. False when left out."],
                                 "workspace": workspaceProperty,
                                 "space": ["type": "string", "description": "A space of the workspace (a lane such as Review or Verify), by id or name, when the user names one "
                                     + "for a handoff: the session the prompt goes to is put in it as well. With an assistant it needs ticket or pr_url."],
                                 "text": ["type": "string", "maxLength": AgentInbox.textLimit, "description": "The task and context for the receiving agent, up to \(AgentInbox.textLimit) characters. For a longer handoff, include the absolute path to a readable transcript and say what to resume."]],
                    required: ["text"], readOnly: false) { args in
                let links: [LinkEntity]?
                if let raw = args["links"] {
                    guard let values = raw as? [String] else { throw MCPToolError("links must be an array of strings.") }
                    links = try values.map { value in
                        guard let entity = LinkTargets.parse(value) else { throw MCPToolError("Unrecognized agent link: " + value) }
                        return entity
                    }
                } else { links = nil }
                let wait = args["async"] as? Bool != true
                if let main = mainAddress(args) {
                    guard links?.isEmpty != false else { throw MCPToolError("links applies to an agent. Main accepts a report.") }
                    guard let text = FilterLogic.text(args, "text") else { throw MCPToolError("text is required.") }
                    let request = ReportRequest(id: UUID().uuidString, workspace: main, title: nil, text: text, source: sources.notices.source(), created: now())
                    return try sources.notices.ask(AgentInbox.encode(request), id: request.id, name: AgentReports.requestName(request.id), what: "the message").message
                }
                let urls = (args["pr_urls"] as? [Any])?.compactMap { $0 as? String } ?? []
                if !urls.isEmpty {
                    let prs: [LinkedPR]
                    switch PullRequestSets.linked(urls) {
                    case .success(let found): prs = found
                    case .failure(let error): throw MCPToolError(error.message)
                    }
                    guard prs.count > 1 else { throw MCPToolError(AgentSetError.needTwo.message) }
                    for pr in prs {
                        try sources.checkDelegation(AgentTarget(key: pr.url, title: pr.label), args: args, agents: sources.agents())
                    }
                    let title = "\(prs.count) pull requests (\(PullRequestSets.summary(prs)))"
                    let space = try sources.space(args, target: AgentTarget(key: prs[0].url, title: title), agents: sources.agents())
                    switch AgentInbox.request(agent: prs[0].url, text: args["text"] as? String ?? "", now: now(), prs: prs.map(\.url), space: space, links: links) {
                    case .failure(let error): throw MCPToolError(error.message)
                    case .success(let made):
                        return try submit(made, title: title, role: nil, waitsForUser: true, wait: wait, sources: sources,
                                          timeout: max(sources.replyTimeout, TimeInterval(RoleTools.waitSeconds()) + 60), now: now())
                    }
                }
                guard var target = try sources.target(args) else { throw MCPToolError("agent is required.") }
                if !Assistants.isKey(target.key),
                   let raw = FilterLogic.text(args, "agent") ?? FilterLogic.text(args, "pr_url"), let pr = GitHubLink.pullRequest(at: raw) {
                    target = AgentTarget(key: pr.url, title: AgentOverview.prTitle(pr.url))
                }
                try sources.checkDelegation(target, args: args, agents: sources.agents())
                var ticket: String?
                if let text = (args["ticket"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    guard Assistants.isKey(target.key) else { throw MCPToolError("ticket only applies when agent is an assistant (its role name), not \(target.title).") }
                    let projects = sources.workspaces.file().workspaces.first { $0.id == Assistants.parse(key: target.key)?.workspace }?.jiraProjects ?? []
                    switch TicketSessions.ticket(text, projects: projects) {
                    case .success(let key): ticket = key
                    case .failure(let error): throw MCPToolError(error.message)
                    }
                }
                var pr: String?
                if Assistants.isKey(target.key), let text = (args["pr_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    switch TicketSessions.pullRequest(text) {
                    case .success(let url): pr = url
                    case .failure(let error): throw MCPToolError(error.message)
                    }
                }
                let space = try sources.space(args, target: target, agents: sources.agents())
                if space != nil, Assistants.isKey(target.key), ticket == nil, pr == nil {
                    throw MCPToolError("space tags a session: with an assistant as agent, give ticket or pr_url too.")
                }
                let request: AgentInbox.Request
                switch AgentInbox.request(agent: target.key, text: args["text"] as? String ?? "", now: now(), ticket: ticket,
                                          newSession: ticket == nil && pr == nil ? nil : args["new_session"] as? Bool, pr: pr, space: space, links: links) {
                case .success(let made): request = made
                case .failure(let error): throw MCPToolError(error.message)
                }
                let waitsForUser = ticket != nil || pr != nil || GitHubLink.pullRequest(at: target.key) != nil
                let timeout = waitsForUser ? max(sources.replyTimeout, TimeInterval(RoleTools.waitSeconds()) + 60) : sources.replyTimeout
                let role = Assistants.isKey(target.key) ? sources.agents().first { $0.key == target.key }?.role ?? target.title : nil
                return try submit(request, title: target.title, role: role, waitsForUser: waitsForUser, wait: wait, sources: sources, timeout: timeout, now: now())
            },
        ]
    }

    /// The workspace `agent: "Main"` (or a Main's key) names, as the argument of a report: empty for the caller's own; nil when the call is not for a Main.
    static func mainAddress(_ args: [String: Any]) -> String?? {
        guard let text = FilterLogic.text(args, "agent"), FilterLogic.text(args, "pr_url") == nil, !(args["pr_urls"] is [Any]) else { return nil }
        if text.caseInsensitiveCompare("main") == .orderedSame { return .some(FilterLogic.text(args, "workspace")) }
        guard Workspaces.isMainKey(text), text != Workspaces.legacyMainKey, let id = Workspaces.id(ofMainKey: text) else { return nil }
        return .some(FilterLogic.text(args, "workspace") ?? id)
    }

    /// Hands the app a prompt and returns how it went; with `wait` false it only leaves the prompt, with a record `request_status` reads.
    static func submit(_ request: AgentInbox.Request, title: String, role: String?, waitsForUser: Bool, wait: Bool, sources: AgentSources,
                       timeout: TimeInterval, now: Date) throws -> String {
        guard wait else {
            let record = RequestStatuses.record(for: request, target: title, role: role, waitsForUser: waitsForUser, waitSeconds: RoleTools.waitSeconds(), now: now)
            try leave(AgentInbox.encode(record), name: RequestStatuses.recordName(record.id), inbox: sources.inbox, what: "the request record")
            try leave(AgentInbox.encode(request), name: AgentInbox.requestName(request.id), inbox: sources.inbox, what: "the prompt")
            return RequestStatuses.markdown(RequestStatuses.status(record, reply: nil, inInbox: true, decisions: [], agents: [], now: now))
        }
        let reply = try deliver(request, inbox: sources.inbox, timeout: timeout, pickupTimeout: sources.replyTimeout)
        if reply.status == .rejected { throw MCPToolError(AgentInbox.replyText(reply, title: title)) }
        return AgentInbox.replyText(reply, title: title)
    }

    /// Writes the request where the app looks and waits for its answer.
    static func deliver(_ request: AgentInbox.Request, inbox: URL, timeout: TimeInterval, pickupTimeout: TimeInterval? = nil) throws -> AgentInbox.Reply {
        try exchange(AgentInbox.encode(request), id: request.id, name: AgentInbox.requestName(request.id), inbox: inbox, timeout: timeout,
                     what: "the prompt", pickupTimeout: pickupTimeout)
    }

    /// Leaves `data` in the inbox under `name`.
    static func leave(_ data: Data, name: String, inbox: URL, what: String) throws {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        do { try data.write(to: inbox.appendingPathComponent(name), options: .atomic) } catch {
            throw MCPToolError("Could not hand \(what) to WorkTime: \(error.localizedDescription)")
        }
    }

    /// Leaves `data` in the inbox under `name` and waits for the app's reply file with the same id.
    static func exchange<Reply: Decodable>(_ data: Data, id: String, name: String, inbox: URL, timeout: TimeInterval, what: String, pickupTimeout: TimeInterval? = nil) throws -> Reply {
        let fileManager = FileManager.default
        let requestURL = inbox.appendingPathComponent(name)
        let replyURL = inbox.appendingPathComponent(AgentInbox.replyName(id))
        try leave(data, name: name, inbox: inbox, what: what)
        let report = AgentReports.isRequest(name)
        if report { AgentDiagnostics.record("report.inbox.written", request: id) }
        let deadline = Date().addingTimeInterval(timeout)
        let pickupDeadline = Date().addingTimeInterval(pickupTimeout ?? timeout)
        while Date() < deadline {
            if Date() >= pickupDeadline, fileManager.fileExists(atPath: requestURL.path) { break }
            if let data = try? Data(contentsOf: replyURL), let reply = AgentInbox.decode(Reply.self, from: data) {
                if report { AgentDiagnostics.record("report.reply.received", request: id) }
                try? fileManager.removeItem(at: replyURL)
                return reply
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? fileManager.removeItem(at: requestURL)
        if report { AgentDiagnostics.record("report.reply.timeout", request: id) }
        throw MCPToolError("WorkTime did not take \(what) within \(Int(timeout)) seconds. Is the app running?")
    }

    /// Slack mentions still needing the user and unread DMs, with the token the app saved, read without renewing it. The fetch starts at once;
    /// the returned call waits for it. Nil when Slack is not set up. `explicit` is a call that asked for Slack alone and may wait for the live answer.
    static func slackAttention(explicit: Bool, secrets: URL = AppPaths.secrets, now: Date = Date()) -> () -> String? {
        let store = FileSecretStore(folder: secrets, name: TokenStore.slackService)
        guard let stored = store.key(for: TokenStore.slack.account).flatMap({ String(data: $0, encoding: .utf8) }),
              let auth = SlackAuth(stored: stored) else { return { nil } }
        if SlackLogic.needsRefresh(auth, now: now) { return { "The Slack sign-in needs renewing; open the Slack panel in WorkTime.\n" } }
        let client = SlackClient(token: auth.accessToken)
        let marks = SlackLogic.marks(CFPreferencesCopyAppValue(SlackLogic.marksKey as CFString, appDomain as CFString), now: now)
        let section = SlackAttention.start(key: auth.accessToken, wait: explicit ? SlackAttention.timeout : SlackAttention.budget) {
            try await SlackAttention.section(client: client, key: auth.accessToken, marks: marks, now: Date())
        }
        return { section() }
    }

    /// Runs async work from the synchronous tool handlers; nil when it takes longer than `timeout`.
    static func blocking(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> String) -> Result<String, Error>? {
        let box = ResultBox(), done = DispatchSemaphore(value: 0)
        let task = Task {
            do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            return nil
        }
        return box.value
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<String, Error>?
}
