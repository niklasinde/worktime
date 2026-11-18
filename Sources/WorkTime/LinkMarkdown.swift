import Foundation

extension LinkTables {
    static let listLimit = 300

    private static func line(_ entity: LinkEntity, labels: LinkLabels, source: LinkSource? = nil, via: String? = nil) -> String {
        var text = "`\(entity.key)`"
        let name = labels.name(entity)
        if name != entity.id { text += " \(name)" }
        if let detail = labels.detail(entity) { text += ": \(detail)" }
        if let status = labels.status(entity) { text += " [\(status.text)]" }
        if let source { text += " (\(source.rawValue))" }
        if let via { text += " via `\(via)`" }
        return text
    }

    /// What the table says about `entity`: what it is linked to and, from two hops, what is related through those; or every link when none is given.
    static func markdown(_ table: LinkTable, entity: LinkEntity?, depth: Int, kind: LinkKind? = nil, labels: LinkLabels) -> String {
        guard let entity else {
            let edges = table.active
            guard !edges.isEmpty else { return "No links yet.\n" }
            var lines = ["\(edges.count) links (each once, `kind:id` at both ends):"]
            lines += edges.prefix(listLimit).map { "- `\($0.from.key)` \u{2194} `\($0.to.key)` (\($0.source.rawValue))" }
            if edges.count > listLimit { lines.append("\u{2026} and \(edges.count - listLimit) more; ask for one entity.") }
            return lines.joined(separator: "\n") + "\n"
        }
        let near = table.neighbors(of: entity, kind: kind)
        var lines = ["# " + line(entity, labels: labels), near.isEmpty ? "No links." : "Linked (\(near.count)):"]
        lines += near.map { "- " + line($0, labels: labels, source: table.edge(LinkPair(entity, $0))?.source) }
        if depth >= 2 {
            let reached = table.related(to: entity, depth: 2).filter { $0.depth == 2 && (kind == nil || $0.entity.kind == kind) }
            lines.append(reached.isEmpty ? "Nothing further away." : "Related (\(reached.count)):")
            lines += reached.map { "- " + line($0.entity, labels: labels, via: $0.via.key) }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
