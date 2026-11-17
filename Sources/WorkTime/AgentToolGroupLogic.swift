import Foundation

/// How the transcript is laid out: runs of finished tool calls fold into one row so the answers stay in view.
enum AgentToolGroups {
    enum Block: Identifiable, Equatable {
        case item(AgentItem)
        case tools(id: String, items: [AgentItem], label: String)
        /// The calls nobody was there to approve, gathered into one row at the end of an unattended run.
        case refused(id: String, items: [AgentItem], label: String)

        var id: String {
            switch self {
            case .item(let item): item.id
            case .tools(let id, _, _), .refused(let id, _, _): id
            }
        }
    }

    static let minimumGroup = 2

    /// Finished, successful calls that follow one another are grouped; a running call, a failed one, a question and every other item stays on its own.
    /// A permission prompt shows as its tool row once answered, and the same call refused again folds into the row before it. In an
    /// unattended run the refused calls are gathered at the end instead.
    static func blocks(_ items: [AgentItem], unattended: Bool = false) -> [Block] {
        var items = collapsed(merged(items))
        var refused: [AgentItem] = []
        if unattended {
            refused = items.filter { $0.decision == false }
            items.removeAll { $0.decision == false }
        }
        var blocks = grouped(items)
        if !refused.isEmpty {
            let count = refused.reduce(0) { $0 + $1.repeats }
            blocks.append(.refused(id: "refused-" + refused[0].id, items: refused, label: refusedLabel(count)))
        }
        return blocks
    }

    /// The block of the transcript that shows the item: its own, the group of tool rows it is in, or the row its permission prompt was merged into.
    static func blockID(containing id: String, in items: [AgentItem], unattended: Bool = false) -> String? {
        let call = items.first { $0.id == id }?.call
        for block in blocks(items, unattended: unattended) {
            let shown: [AgentItem]
            switch block {
            case .item(let item): shown = [item]
            case .tools(_, let items, _), .refused(_, let items, _): shown = items
            }
            if shown.contains(where: { $0.id == id || (call != nil && $0.call == call) }) { return block.id }
        }
        return nil
    }

    static func refusedLabel(_ count: Int) -> String {
        "\(count) call\(count == 1 ? " was" : "s were") refused: nobody was there to approve"
    }

    /// Each tool row with its permission prompt: the prompt goes once answered, and the row waits behind it until then.
    static func merged(_ items: [AgentItem]) -> [AgentItem] {
        var asked: [String: Bool?] = [:]
        var calls: Set<String> = []
        for item in items {
            guard let call = item.call else { continue }
            switch item.kind {
            case .permission(_, _, _, _, let allowed): asked[call] = .some(allowed)
            case .tool: calls.insert(call)
            default: break
            }
        }
        return items.compactMap { item in
            guard let call = item.call, calls.contains(call), let answer = asked[call] else { return item }
            switch item.kind {
            case .permission: return answer == nil ? item : nil
            case .tool:
                guard let answer else { return nil }
                var item = item
                item.decision = answer
                return item
            default: return item
            }
        }
    }

    /// The same call refused again right after it folds into one row, counted.
    static func collapsed(_ items: [AgentItem]) -> [AgentItem] {
        var result: [AgentItem] = []
        for item in items {
            if item.decision == false, var last = result.last, last.decision == false, case .tool(let name, _, let detail, _, _, _, _) = item.kind,
               case .tool(let lastName, _, let lastDetail, _, _, _, _) = last.kind, name == lastName, detail == lastDetail {
                last.repeats += item.repeats
                result[result.count - 1] = last
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func grouped(_ items: [AgentItem]) -> [Block] {
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
            if case .tool(_, _, _, let result, let isError, _, _) = item.kind, result != nil, !isError, item.decision != false {
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
