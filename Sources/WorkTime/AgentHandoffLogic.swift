import Foundation

/// What one provider did in an agent that the other has not seen, passed along once with the next prompt after a switch.
enum AgentHandoff {
    static let limit = 12_000
    static let trimmedNote = "(earlier turns trimmed)"
    private static let lead = "You are taking over from "
    private static let close = "\n</handoff>\n\n"

    /// The turns made at or after `since`: prompts and replies in full, tool calls as one line each.
    static func digest(items: [AgentItem], since: Date, from provider: AgentProvider, limit: Int = limit) -> String {
        let lines = items.filter { $0.date >= since }.compactMap { line($0, provider: provider) }
        return fit(lines, limit: limit)
    }

    /// A pending digest followed by a newer one, still within the limit, keeping the newest turns.
    static func merge(_ pending: String?, _ new: String, limit: Int = limit) -> String {
        guard let pending, !pending.isEmpty else { return new }
        guard !new.isEmpty else { return pending }
        let lines = (pending + "\n\n" + new).components(separatedBy: "\n\n")
        let turns = lines.filter { $0 != trimmedNote }
        return fit(turns, limit: limit, trimmed: turns.count < lines.count)
    }

    static func prompt(_ text: String, digest: String?, from provider: AgentProvider) -> String {
        guard let digest, !digest.isEmpty else { return text }
        return lead + "\(provider.title). The conversation below happened in that session, which you cannot see. Continue from it.\n<handoff>\n"
            + digest + close + text
    }

    /// The user's own text of a prompt that carried a handoff.
    static func strip(_ text: String) -> String {
        guard text.hasPrefix(lead), let range = text.range(of: close) else { return text }
        return String(text[range.upperBound...])
    }

    private static func line(_ item: AgentItem, provider: AgentProvider) -> String? {
        switch item.kind {
        case .user(let text): return "User: " + strip(text)
        case .text(let text): return text.isEmpty ? nil : "\(provider.title): " + text
        case .tool(let name, let summary, _, _, let isError, _, _):
            return "[\(AgentLogic.displayName(name))" + (summary.isEmpty ? "" : " \(summary)") + (isError ? ", failed" : "") + "]"
        default: return nil
        }
    }

    private static func fit(_ lines: [String], limit: Int, trimmed: Bool = false) -> String {
        var kept: [String] = [], size = trimmed ? trimmedNote.count + 2 : 0, cut = trimmed
        for line in lines.reversed() {
            let cost = line.count + 2
            if size + cost > limit {
                if kept.isEmpty { kept.append(String(line.suffix(limit - trimmedNote.count - 4))) }
                cut = true
                break
            }
            kept.append(line)
            size += cost
        }
        if cut { kept.append(trimmedNote) }
        return kept.reversed().joined(separator: "\n\n")
    }
}
