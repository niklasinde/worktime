import Foundation

/// One thing that waits for the user's own answer, as the app lists it for `pending_decisions`. Nothing here can be answered through MCP.
struct PendingDecision: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case permission, reuseSession = "reuse_session", missingTool = "missing_tool", blocked
        case reviewDraft = "review_draft", automationAsk = "automation_ask", urgentNotice = "urgent_notice"
    }

    var id: String
    var kind: Kind
    var title: String
    var agent: String?
    var agentTitle: String?
    var workspace: String?
    var session: String?
    var ticket: String?
    var role: String?
    var tool: String?
    var input: String?
    var preview: String?
    var pullRequest: String?
    var verdict: String?
    var comments: Int?
    var created: Date
    var link: String?
}

/// An approval card as the attention center holds it, without the view model around it.
struct DecisionApproval: Equatable {
    enum Kind: Equatable { case call, roleTool, blocked }

    var agent: String
    var permission: String
    var kind: Kind
    var title: String
    var body: String
    var created: Date
}

enum PendingDecisions {
    static let fileName = "decisions.json"
    static let staleAfter: TimeInterval = 300

    struct File: Codable, Equatable {
        var written: Date
        var decisions: [PendingDecision]
    }

    static func encode(_ decisions: [PendingDecision], now: Date) -> Data { AgentInbox.encode(File(written: now, decisions: decisions)) }

    static func decode(_ data: Data?) -> File? { data.flatMap { AgentInbox.decode(File.self, from: $0) } }

    /// Every decision waiting, oldest first: the permission prompts, missing-tool requests and blocked turns of the agents, the reuse-or-new
    /// questions, the review drafts and the automation asks and urgent notifications.
    static func make(approvals: [DecisionApproval], ticketAsks: [TicketAsk], notices: [AgentNotice], agents: [AgentState],
                     titles: [String: String]) -> [PendingDecision] {
        let byKey = Dictionary(agents.map { ($0.key, $0) }) { first, _ in first }
        var decisions: [PendingDecision] = []
        for approval in approvals {
            let state = byKey[approval.agent]
            let kind: PendingDecision.Kind = switch approval.kind {
            case .call: .permission
            case .roleTool: .missingTool
            case .blocked: .blocked
            }
            decisions.append(PendingDecision(
                id: "approval:\(approval.agent):\(approval.permission)", kind: kind, title: approval.title, agent: approval.agent,
                agentTitle: state?.title ?? titles[approval.agent], workspace: state?.workspace, session: state?.sessionID, ticket: ticket(of: state),
                role: state?.role, tool: kind == .blocked ? nil : state?.pendingTool, input: kind == .permission ? state?.pendingInput ?? oneLine(approval.body) : oneLine(approval.body),
                pullRequest: state?.prURL ?? state?.sessionPR, created: approval.created, link: link(agent: approval.agent, state: state)))
        }
        for ask in ticketAsks {
            decisions.append(PendingDecision(
                id: "ask:\(ask.id)", kind: .reuseSession, title: ask.title, agent: ask.existing.key, agentTitle: ask.assistantName, workspace: ask.workspace,
                session: byKey[ask.existing.key]?.sessionID, ticket: ask.ticket, role: ask.assistantName,
                preview: oneLine(ask.existing.excerpt.isEmpty ? ask.text : ask.existing.excerpt), pullRequest: ask.pullRequest, created: ask.created,
                link: OpenLinks.link(ask.ticket.map(OpenTarget.ticket) ?? .agent(ask.existing.key))))
        }
        for notice in notices where Decisions.needsAnswer(notice) {
            let agent = notice.source.agent
            let state = agent.flatMap { byKey[$0] }
            let base = PendingDecision(
                id: "notice:\(notice.id)", kind: .urgentNotice, title: notice.title, agent: agent, agentTitle: notice.source.title ?? notice.source.label(titles: titles),
                workspace: notice.source.workspace, session: state?.sessionID, preview: notice.body.map { oneLine($0) }, created: notice.created, link: noticeLink(notice))
            if let reviews = notice.reviews, !reviews.isEmpty {
                for review in reviews {
                    var decision = base
                    decision.id = "review:\(review.id)"
                    decision.kind = .reviewDraft
                    decision.title = "Review draft ready: \(review.reference)"
                    decision.pullRequest = review.pr
                    decision.verdict = review.verdict.rawValue
                    decision.comments = review.comments.count
                    decision.preview = oneLine(review.summary)
                    decision.link = GitHubLink.appLink(for: review.pr)
                    decisions.append(decision)
                }
            } else if let ask = notice.ask {
                var decision = base
                decision.kind = .automationAsk
                decision.ticket = ask.ticket
                decision.pullRequest = ask.pullRequest ?? ask.pullRequests?.first
                decision.preview = oneLine(ask.eventText ?? notice.body ?? ask.prompt)
                decision.role = ask.agent
                decisions.append(decision)
            } else {
                decisions.append(base)
            }
        }
        return decisions.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    private static func ticket(of state: AgentState?) -> String? {
        state?.jiraKey ?? state?.title.firstMatch(of: #/\b([A-Z][A-Z0-9]+-[0-9]+)\b/#).map { String($0.1) }
    }

    private static func link(agent: String, state: AgentState?) -> String {
        if let url = state?.prURL ?? GitHubLink.pullRequest(at: agent)?.url { return GitHubLink.agentLink(for: url) }
        return OpenLinks.link(.agent(agent))
    }

    private static func noticeLink(_ notice: AgentNotice) -> String? {
        if let link = notice.link, case .pullRequest(let target)? = NoticeLogic.link(link) { return GitHubLink.appLink(for: target.url) }
        return notice.source.agent.map { OpenLinks.link(.agent($0)) }
    }

    static func oneLine(_ text: String, limit: Int = 200) -> String { Timeline.clip(text, limit) }

    // MARK: Reading

    static func age(_ decision: PendingDecision, now: Date) -> String { ClaudePlugin.ago(decision.created, now: now) }

    static func markdown(_ file: File, now: Date, kind: PendingDecision.Kind? = nil) -> String {
        let shown = file.decisions.filter { kind == nil || $0.kind == kind }
        var lines = [shown.isEmpty ? "Nothing waits for the user."
                     : "\(shown.count) decision\(shown.count == 1 ? "" : "s") wait for the user. Only they can answer them, in the app; open the link to see one.",
                     "State written \(ClaudePlugin.ago(file.written, now: now))."]
        if now.timeIntervalSince(file.written) > staleAfter { lines.append("The state is old: WorkTime may not be running.") }
        for decision in shown {
            var facts = [decision.kind.rawValue, decision.agentTitle, decision.tool.map { "tool \($0)" }, decision.ticket, decision.role.map { "role \($0)" },
                         decision.verdict.map { "verdict \($0)" }, decision.comments.map { "\($0) comment\($0 == 1 ? "" : "s")" }, "waiting \(age(decision, now: now))"]
                .compactMap { $0 }
            if let pr = decision.pullRequest { facts.append(pr) }
            lines.append("- **\(decision.title)** \u{00B7} " + facts.joined(separator: " \u{00B7} "))
            if let input = decision.input, !input.isEmpty { lines.append("  input: \(input)") }
            if let preview = decision.preview, !preview.isEmpty { lines.append("  preview: \(preview)") }
            lines.append("  id \(decision.id)" + (decision.link.map { " \u{00B7} \($0)" } ?? ""))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether a decision belongs to a session, by the session id or the agent's key.
    static func waiting(on session: AgentState, in decisions: [PendingDecision]) -> [PendingDecision] {
        decisions.filter { ($0.session != nil && $0.session == session.sessionID) || $0.agent == session.key }
    }
}
