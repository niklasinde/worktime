import Foundation

/// A WorkTime tool an assistant's role file leaves out of its `tools:` list, and what happens when the assistant calls it anyway:
/// the user is asked, the call waits, and Add puts the tool in the file.
enum RoleTools {
    enum Tier: String, Equatable {
        /// Runs without asking once it is on the list.
        case read
        /// Asks for every call even when it is on the list.
        case ask
        /// Asks for every call and changes what runs on its own or sends prompts, so adding it carries a warning.
        case risky
    }

    static let prefix = "mcp__worktime__"
    /// How long an unattended run waits for the user's answer, in minutes, unless Settings says otherwise.
    static let defaultWaitMinutes = 30
    static let waitKey = "agentRoleToolWaitMinutes"

    static func shortName(_ tool: String) -> String { tool.hasPrefix(prefix) ? String(tool.dropFirst(prefix.count)) : tool }

    static func fullName(_ tool: String) -> String { tool.hasPrefix("mcp__") ? tool : prefix + tool }

    static func tier(of tool: String, builtIn: AgentBuiltIn? = AgentRules.builtIn) -> Tier {
        let full = fullName(tool)
        if builtIn?.alwaysAskRisky?.contains(full) == true { return .risky }
        return builtIn?.alwaysAsk.contains(full) == true ? .ask : .read
    }

    /// The question's offer: the tool and its tier, which the card, the notification and the notch read.
    static func offer(tool: String, tier: Tier, assistant: String? = nil) -> AgentRule {
        AgentRule(kind: .role, value: tool, title: tier.rawValue, workspaceName: assistant)
    }

    static func tier(of rule: AgentRule) -> Tier { Tier(rawValue: rule.title ?? "") ?? .read }

    static func role(in offer: [AgentRule]) -> AgentRule? { offer.first { $0.kind == .role } }

    static func waitSeconds(defaults: UserDefaults = .standard) -> Int {
        let minutes = defaults.object(forKey: waitKey) as? Int ?? defaultWaitMinutes
        return max(1, minutes) * 60
    }

    // MARK: Words

    static func title(tool: String, assistant: String?) -> String {
        "\(assistant ?? "The assistant") wants to use \(AgentLogic.displayName(tool)), which is not in its tools"
    }

    /// The warning shown beside a tool that asks for every call, nil for a tool that runs without asking once it is on the list.
    static func note(tool: String, tier: Tier) -> String? {
        switch tier {
        case .read: return nil
        case .ask: return "Even on the list it asks about every call."
        case .risky: return AgentRules.riskNote(tool) + " Even on the list it asks about every call."
        }
    }

    static func approval(agent: String, tool: String, tier: Tier) -> (title: String, body: String) {
        let body = "Wants to use \(AgentLogic.displayName(tool)), which is not in its tools." + (note(tool: tool, tier: tier).map { " " + $0 } ?? "")
        return ("\(agent) needs a tool", body)
    }

    /// What the agent reads when the user denied the question, or an unattended run's wait ended.
    static func refusal(tool: String, waited: Bool, unattended: Bool) -> String {
        if waited { return RoleToolWait.timeoutText(tool) }
        if unattended {
            return "\(tool) is not one of this assistant's tools. Nobody was there to answer, so the user will be asked after this run whether to add it. "
                + "Carry on without it and say what could not be done."
        }
        return "The user denied this tool call."
    }

    // MARK: The role file

    /// The file's text with `tool` on its `tools:` list, everything else as it was: an inline list gets the name at its end, a block list
    /// an item, and a file without the key a new line. The text itself when the tool is there already; nil when the file has no front matter
    /// or the result would not read back with the tool on the list.
    static func adding(_ tool: String, to text: String) -> String? {
        let name = shortName(tool)
        guard !Assistants.parse(slug: "", text: text).tools.contains(where: { shortName($0) == name }) else { return text }
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return nil }
        let end = lines[0].hasSuffix("\r") ? "\r" : ""
        if let at = lines[1..<close].firstIndex(where: { $0.hasPrefix("tools:") }) {
            let value = lines[at].dropFirst("tools:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                var next = at + 1, indent = "  "
                while next < close, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                    indent = String(lines[next].prefix { $0 == " " || $0 == "\t" })
                    next += 1
                }
                lines.insert(indent + "- " + name + end, at: next)
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                let inner = value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                lines[at] = "tools: [" + (inner.isEmpty ? name : inner + ", " + name) + "]" + end
            } else {
                lines[at] = "tools: " + value + ", " + name + end
            }
        } else {
            lines.insert("tools: [" + name + "]" + end, at: close)
        }
        let result = lines.joined(separator: "\n")
        return Assistants.parse(slug: "", text: result).tools.contains(where: { shortName($0) == name }) ? result : nil
    }
}

/// The pieces of the wait that need no window: what the agent is told when it ends, and what the routine's row says while it lasts.
enum RoleToolWait {
    static func timeoutText(_ tool: String) -> String {
        "\(tool) is not one of this assistant's tools, and nobody answered the question about adding it in time. Carry on without it, or say what could not be done."
    }

    /// The routine row's second line while its run waits for the user.
    static func rowText(tool: String) -> String { "waiting for you: \(AgentLogic.displayName(tool))" }
}

/// A tool an unattended run needed that its assistant's list leaves out, kept until the user adds it or dismisses it.
struct RoleToolSuggestion: Codable, Equatable, Identifiable {
    var assistant: String
    var assistantName: String
    var tool: String
    var routine: String
    var created: Date

    var id: String { assistant + "|" + RoleTools.shortName(tool) }
}

enum RoleToolSuggestions {
    static let key = "agentRoleToolSuggestions"
    static let limit = 40

    /// The list with `new` added; one suggestion per assistant and tool, however many runs asked for it.
    static func adding(_ new: RoleToolSuggestion, to list: [RoleToolSuggestion]) -> [RoleToolSuggestion] {
        guard !list.contains(where: { $0.id == new.id }) else { return list }
        return Array((list + [new]).suffix(limit))
    }

    static func removing(_ id: String, from list: [RoleToolSuggestion]) -> [RoleToolSuggestion] { list.filter { $0.id != id } }

    /// Whether the user should be told again about the suggestion: not when it was dismissed, which keeps its id here.
    static func shouldAsk(_ suggestion: RoleToolSuggestion, pending: [RoleToolSuggestion], dismissed: Set<String>) -> Bool {
        !dismissed.contains(suggestion.id) && !pending.contains { $0.id == suggestion.id }
    }

    static func text(_ suggestion: RoleToolSuggestion) -> (title: String, body: String) {
        ("\(suggestion.routine) needed \(AgentLogic.displayName(suggestion.tool))", "Add it to \(suggestion.assistantName)\u{2019}s tools?")
    }

    static func identifier(_ suggestion: RoleToolSuggestion) -> String { identifier(id: suggestion.id) }

    static func identifier(id: String) -> String { "role-tool:" + id }

    static func decode(_ data: Data?) -> [RoleToolSuggestion] {
        data.flatMap { try? JSONDecoder().decode([RoleToolSuggestion].self, from: $0) } ?? []
    }

    static func encode(_ list: [RoleToolSuggestion]) -> Data? { try? JSONEncoder().encode(list) }
}
