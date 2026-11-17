import Foundation

/// When an agent that stops to wait for the user reaches them as a system notification, and what the notification says and does.
enum AgentAttention {
    static let settingKey = "agentNotifyAttention"
    static let approvalCategory = "agent-approval"
    static let sessionApprovalCategory = "agent-approval-session"
    static let roleToolCategory = "agent-role-tool"
    static let roleSuggestionCategory = "agent-role-suggestion"
    static let dismissAction = "agent-dismiss"
    static let blockedCategory = "agent-blocked"
    static let questionCategory = "agent-question"
    static let handoffCategory = "agent-handoff"
    static let allowAction = "agent-allow"
    static let allowSessionAction = "agent-allow-session"
    static let addToolAction = "agent-add-tool"
    static let fixAction = "agent-fix-continue"
    static let denyAction = "agent-deny"
    static let replyAction = "agent-reply"
    static let stopAction = "agent-stop"
    static let agentKey = "agentAttentionAgent"
    static let requestKey = "agentAttentionRequest"
    static let bodyLimit = 400
    static let handoffLimit = 400
    static let questionLimit = 200

    enum Response: Equatable {
        case allow, allowSession, deny, answer(String), stop, open, addTool, fixAndContinue, dismiss
    }

    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }

    /// Routines run unattended and deny what needs approval; an agent the user is looking at asks in its own window.
    static func shouldNotify(enabled: Bool, isRoutine: Bool, isShown: Bool) -> Bool { enabled && !isRoutine && !isShown }

    /// A question about a tool the assistant's list leaves out is also asked of the user while a routine waits for the answer.
    static func shouldNotifyRoleTool(enabled: Bool, isShown: Bool) -> Bool { enabled && !isShown }

    /// The buttons of an approval: Allow for this session only where the prompt offers it.
    static func approvalCategory(sessionOffered: Bool, roleTool: Bool = false) -> String {
        roleTool ? roleToolCategory : sessionOffered ? sessionApprovalCategory : approvalCategory
    }

    static func approvalIdentifier(agent: String, permission: String) -> String { "agent-approval:\(agent):\(permission)" }

    static func questionIdentifier(agent: String) -> String { "agent-question:\(agent)" }

    static func approval(agent: String, tool: String, summary: String) -> (title: String, body: String) {
        let call = summary.isEmpty ? tool : "\(tool): \(summary)"
        return ("\(agent) needs approval", clipped(call, to: bodyLimit))
    }

    static func question(agent: String, text: String) -> (title: String, body: String) {
        ("\(agent) is asking", clipped(text, to: questionLimit))
    }

    /// What a tap on the notification means: the buttons answer, a typed reply is the answer, anything else opens the agent.
    static func response(action: String, text: String?) -> Response {
        switch action {
        case allowAction: return .allow
        case allowSessionAction: return .allowSession
        case denyAction: return .deny
        case addToolAction: return .addTool
        case fixAction: return .fixAndContinue
        case dismissAction: return .dismiss
        case stopAction: return .stop
        case replyAction:
            let answer = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? .open : .answer(answer)
        default: return .open
        }
    }

    static func asks(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'\u{201D}\u{2019})*_`")))
        return trimmed.hasSuffix("?")
    }

    /// The last paragraph of the reply the turn ended on, when it is a question for the user.
    static func question(in items: [AgentItem]) -> String? {
        let lastPrompt = items.lastIndex { if case .user = $0.kind { true } else { false } }
        let turn = items[(lastPrompt.map { $0 + 1 } ?? 0)...]
        guard let last = turn.last(where: { if case .text = $0.kind { true } else { false } }),
              case .text(let text) = last.kind, asks(text) else { return nil }
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return paragraphs.last
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }
}
