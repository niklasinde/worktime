import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func text(_ id: String, _ value: String) -> AgentItem { AgentItem(id: id, kind: .text(value)) }
private func user(_ value: String) -> AgentItem { AgentItem(id: "user-0", kind: .user(value)) }

let agentAttentionTests: [(name: String, run: () throws -> Void)] = [
    ("attention: notifies with the setting on, for an agent that is not a routine and not in front", {
        check(AgentAttention.shouldNotify(enabled: true, isRoutine: false, isShown: false), "notifies")
        check(!AgentAttention.shouldNotify(enabled: false, isRoutine: false, isShown: false), "setting off")
        check(!AgentAttention.shouldNotify(enabled: true, isRoutine: true, isShown: false), "a routine denies instead")
        check(!AgentAttention.shouldNotify(enabled: true, isRoutine: false, isShown: true), "already in front")
        let defaults = UserDefaults(suiteName: "attention-\(UUID().uuidString)")!
        check(AgentAttention.enabled(defaults: defaults), "on by default")
        defaults.set(false, forKey: AgentAttention.settingKey)
        check(!AgentAttention.enabled(defaults: defaults), "off when switched off")
    }),
    ("attention: what the agent said just before it asked is the reason, the last words of it when long", {
        let ask = AgentItem(id: "p", kind: .permission(tool: "Bash", summary: "gh pr diff 12", detail: "gh pr diff 12", allowed: nil))
        check(AgentAttention.context(in: [user("go"), text("t1", "First."), text("t2", "I need the diff to check the migration."), ask]) == "I need the diff to check the migration.", "the last text before the call")
        check(AgentAttention.context(in: [user("go"), ask]).isEmpty, "nothing said")
        check(AgentAttention.context(in: [text("t1", "Before."), ask, text("t2", "After the call.")]) == "Before.", "only what came before")
        let long = AgentAttention.context(in: [text("t", String(repeating: "a", count: 900) + "END"), ask], limit: 50)
        check(long.count == 50 && long.hasSuffix("END") && long.hasPrefix("\u{2026}"), "the end of a long reply: \(long.count)")
    }),
    ("attention: the approval names the agent and the call, on one clipped line", {
        let short = AgentAttention.approval(agent: "ISD-13312", tool: "Bash", summary: "git push origin main")
        check(short.title == "ISD-13312 needs approval", "title: \(short.title)")
        check(short.body == "Bash: git push origin main", "body: \(short.body)")
        check(AgentAttention.approval(agent: "Main", tool: "Chrome", summary: "").body == "Chrome", "no summary, just the tool")
        let long = AgentAttention.approval(agent: "Main", tool: "Bash", summary: "echo\n" + String(repeating: "x", count: 400))
        check(long.body.count == AgentAttention.bodyLimit && long.body.hasSuffix("\u{2026}") && !long.body.contains("\n"), "clipped to one line")
    }),
    ("attention: a tap answers the approval, a typed reply answers the question, anything else opens the agent", {
        check(AgentAttention.response(action: AgentAttention.allowAction, text: nil) == .allow, "allow")
        check(AgentAttention.response(action: AgentAttention.allowSessionAction, text: nil) == .allowSession, "allow for the session")
        check(AgentAttention.response(action: AgentAttention.denyAction, text: nil) == .deny, "deny")
        check(AgentAttention.approvalCategory(sessionOffered: true) == AgentAttention.sessionApprovalCategory, "session button where offered")
        check(AgentAttention.approvalCategory(sessionOffered: false) == AgentAttention.approvalCategory, "plain buttons otherwise")
        check(AgentAttention.response(action: AgentAttention.replyAction, text: "  Yes, go ahead \n") == .answer("Yes, go ahead"), "reply trimmed")
        check(AgentAttention.response(action: AgentAttention.replyAction, text: "  ") == .open, "an empty reply just opens it")
        check(AgentAttention.response(action: "com.apple.UNNotificationDefaultActionIdentifier", text: nil) == .open, "a click opens it")
    }),
    ("attention: a hand-off's whole prompt fits in the approval", {
        let prompt = String(repeating: "word ", count: 70)
        let approval = AgentAttention.approval(agent: "Main", tool: "mcp__worktime__send_to_agent", summary: prompt)
        check(approval.body.contains(prompt.trimmingCharacters(in: .whitespaces)), "a 350 character prompt is not cut")
    }),
    ("attention: the identifiers are per request and per agent, so a repeat replaces instead of piling up", {
        check(AgentAttention.approvalIdentifier(agent: "a", permission: "1") != AgentAttention.approvalIdentifier(agent: "a", permission: "2"), "per request")
        check(AgentAttention.approvalIdentifier(agent: "a", permission: "1") == AgentAttention.approvalIdentifier(agent: "a", permission: "1"), "stable")
        check(AgentAttention.questionIdentifier(agent: "a") != AgentAttention.questionIdentifier(agent: "b"), "per agent")
    }),
    ("attention: a turn that ends on a question gives its last paragraph", {
        check(AgentAttention.asks("Shall I go ahead?"), "plain")
        check(AgentAttention.asks("Shall I go ahead? \n"), "trailing space")
        check(AgentAttention.asks("Is it \"done\"?)"), "closing quote")
        check(!AgentAttention.asks("Done. Say if you want more."), "a statement")
        let items = [user("fix it"), text("text-1", "I found two ways.\n\nWhich one do you want?")]
        check(AgentAttention.question(in: items) == "Which one do you want?", "last paragraph")
        check(AgentAttention.question(in: [user("hi"), text("text-1", "Hello.")]) == nil, "no question")
        check(AgentAttention.question(in: [text("text-0", "Ready?"), user("yes"), text("text-2", "Done.")]) == nil, "an earlier turn's question is not this one's")
        check(AgentAttention.question(in: []) == nil, "empty")
        let long = AgentAttention.question(agent: "Main", text: String(repeating: "q", count: 500) + "?")
        check(long.title == "Main is asking" && long.body.count == AgentAttention.questionLimit, "question clipped")
    }),
]
