import Foundation

/// How the transcript is laid out: runs of finished tool calls fold into one row so the answers stay in view.
enum AgentToolGroups {
    enum Block: Identifiable, Equatable {
        case item(AgentItem)
        case tools(id: String, items: [AgentItem], label: String)

        var id: String {
            switch self {
            case .item(let item): item.id
            case .tools(let id, _, _): id
            }
        }
    }

    static let minimumGroup = 2

    /// Finished, successful calls that follow one another are grouped; a running call, a failed one, a question and every other item stays on its own.
    static func blocks(_ items: [AgentItem]) -> [Block] {
        var blocks: [Block] = []
        var run: [AgentItem] = []
        func flush() {
            if run.count >= minimumGroup {
                blocks.append(.tools(id: "tools-" + run[0].id, items: run, label: label(run)))
            } else {
                blocks += run.map(Block.item)
            }
            run = []
        }
        for item in items {
            if case .tool(_, _, _, let result, let isError, _, _) = item.kind, result != nil, !isError {
                run.append(item)
            } else {
                flush()
                blocks.append(.item(item))
            }
        }
        flush()
        return blocks
    }

    static func label(_ items: [AgentItem]) -> String {
        var counts: [(phrase: (Int) -> String, count: Int)] = []
        var index: [String: Int] = [:]
        for item in items {
            guard case .tool(let name, _, _, _, _, _, _) = item.kind else { continue }
            let (key, phrase) = category(name)
            if let position = index[key] {
                counts[position].count += 1
            } else {
                index[key] = counts.count
                counts.append((phrase, 1))
            }
        }
        let text = counts.map { $0.phrase($0.count) }.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func category(_ tool: String) -> (key: String, phrase: (Int) -> String) {
        func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        switch tool {
        case "Bash": return ("run", { "ran " + plural($0, "command", "commands") })
        case "Read": return ("read", { "read " + plural($0, "file", "files") })
        case "Grep", "Glob": return ("search", { "searched " + plural($0, "time", "times") })
        case "Edit", "Write", "NotebookEdit": return ("edit", { "edited " + plural($0, "file", "files") })
        case "Agent", "Task": return ("agent", { "ran " + plural($0, "subagent", "subagents") })
        default: return ("other", { "made " + plural($0, "other call", "other calls") })
        }
    }
}
