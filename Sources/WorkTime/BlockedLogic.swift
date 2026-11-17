import Foundation

/// A call the turn could not make, with what would let it through, shown when the turn ended after refusals so the user can fix them
/// together and have the same session go on.
struct BlockedCall: Equatable, Identifiable {
    enum Fix: Equatable {
        /// Puts the tool on the assistant's `tools:` list.
        case addTool(String)
        /// Lets the agent use the tool for the rest of the session.
        case allowSession(String)
        /// Saves the rules the permission card offered, for every agent.
        case alwaysAllow([AgentRule])
        /// Turns Claude in Chrome on for this session.
        case chromeOn

        /// Whether Fix and continue applies it by itself; a saved rule for every agent needs its own click.
        var isDefault: Bool {
            if case .alwaysAllow = self { return false }
            return true
        }

        var label: String {
            switch self {
            case .addTool: return "Add to its tools"
            case .allowSession: return "Allow for this session"
            case .alwaysAllow(let rules): return AgentRules.offerButton(rules)
            case .chromeOn: return "Turn Chrome on for this session"
            }
        }
    }

    let id: String
    let tool: String
    let summary: String
    let reason: String
    let fixes: [Fix]
}

enum Blocked {
    static let notInList = "is not one of this assistant's tools"
    static let denied = "The user denied this tool call."
    static let chromePrefix = "mcp__claude-in-chrome__"
    static let limit = 8

    /// The calls of the last turn that were refused, once each, with the fixes that would let them through.
    static func calls(in items: [AgentItem], chromeOn: Bool, assistant: String?) -> [BlockedCall] {
        let start = items.lastIndex { if case .user = $0.kind { true } else { false } }.map { $0 + 1 } ?? 0
        var seen = Set<String>(), found: [BlockedCall] = []
        func add(tool: String, summary: String, reason: String, fixes: [BlockedCall.Fix]) {
            let id = tool + "|" + summary
            guard seen.insert(id).inserted, found.count < limit else { return }
            found.append(BlockedCall(id: id, tool: tool, summary: summary, reason: reason, fixes: fixes))
        }
        for item in items[start...] {
            switch item.kind {
            case .permission(let tool, let summary, _, let offer, let allowed?) where !allowed:
                if RoleTools.role(in: offer) != nil {
                    add(tool: tool, summary: summary, reason: "Not in \(assistant ?? "the assistant")\u{2019}s tools", fixes: [.addTool(tool)])
                } else if AgentRules.sessionOffered(tool: tool) {
                    add(tool: tool, summary: summary, reason: "Denied", fixes: [.allowSession(tool)])
                } else {
                    add(tool: tool, summary: summary, reason: "Denied", fixes: offer.isEmpty ? [] : [.alwaysAllow(offer)])
                }
            case .tool(let name, let summary, _, let result?, true, _, _):
                if name.hasPrefix(RoleTools.prefix), result.contains(notInList) {
                    add(tool: name, summary: summary, reason: "Not in \(assistant ?? "the assistant")\u{2019}s tools", fixes: [.addTool(name)])
                } else if name.hasPrefix(chromePrefix), !chromeOn {
                    add(tool: name, summary: summary, reason: "Claude in Chrome is off", fixes: [.chromeOn])
                } else if result.contains(denied), AgentRules.sessionOffered(tool: name) {
                    add(tool: name, summary: summary, reason: "Denied", fixes: [.allowSession(name)])
                }
            default: break
            }
        }
        return found
    }

    /// The fixes Fix and continue applies, once each.
    static func defaultFixes(_ calls: [BlockedCall]) -> [BlockedCall.Fix] {
        var fixes: [BlockedCall.Fix] = []
        for fix in calls.compactMap({ $0.fixes.first(where: \.isDefault) }) where !fixes.contains(fix) { fixes.append(fix) }
        return fixes
    }

    /// The short message that makes the same session go on.
    static func continueText(_ calls: [BlockedCall]) -> String {
        let names = calls.filter { $0.fixes.contains(where: \.isDefault) }.map { AgentLogic.displayName($0.tool) }
        let list = Array(Set(names)).sorted().joined(separator: ", ")
        return "Continue: the blocked tools are now available" + (list.isEmpty ? "." : " (\(list)). Pick up where you stopped and retry what they blocked.")
    }

    static func notice(agent: String, calls: [BlockedCall]) -> (title: String, body: String) {
        let names = Array(Set(calls.map { AgentLogic.displayName($0.tool) })).sorted().joined(separator: ", ")
        return ("\(agent) was blocked", "\(calls.count) call\(calls.count == 1 ? "" : "s") could not run: \(names).")
    }

    static func identifier(agent: String) -> String { "agent-blocked:\(agent)" }
}
