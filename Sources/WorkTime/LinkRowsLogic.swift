import Foundation

/// How the Links view is organized: one row per agent, per ticket or per pull request.
enum LinkMode: String, CaseIterable, Identifiable {
    case agent, ticket, pullRequest

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agent: "By agent"
        case .ticket: "By ticket"
        case .pullRequest: "By PR"
        }
    }

    var kind: LinkKind {
        switch self {
        case .agent: .agent
        case .ticket: .jira
        case .pullRequest: .githubPR
        }
    }
}

/// What an entity is called and where it stands, from the agents and the lookup cache.
struct LinkLabels {
    var agents: [String: String] = [:]
    var infos: [String: SessionRefInfo] = [:]

    func name(_ entity: LinkEntity) -> String {
        switch entity.kind {
        case .agent: agents[entity.id] ?? entity.id
        case .githubPR: AgentSessions.shortReference(LinkTargets.pullRequestURL(entity.id) ?? entity.id)
        case .branch: String(entity.id.drop { $0 != ":" }.dropFirst())
        case .slackThread: "Slack thread"
        default: entity.id
        }
    }

    func info(_ entity: LinkEntity) -> SessionRefInfo? {
        switch entity.kind {
        case .jira: infos[SessionRef.jira(entity.id).cacheKey]
        case .githubPR: GitHubLink.pasted(entity.id).flatMap { infos[SessionRef($0).cacheKey] }
        default: nil
        }
    }

    func detail(_ entity: LinkEntity) -> String? { info(entity).map(\.title).flatMap { $0.isEmpty ? nil : $0 } }

    /// The pill: a ticket's status, or a pull request's state.
    func status(_ entity: LinkEntity) -> (text: String, kind: JiraStatusCategory?)? {
        guard let info = info(entity) else { return nil }
        if entity.kind == .jira { return info.status.map { ($0, info.statusKind) } }
        guard let state = info.state else { return nil }
        return (info.isDraft && state == "open" ? "draft" : state, state == "merged" ? .done : state == "open" ? .inProgress : nil)
    }

    func text(_ entity: LinkEntity) -> String { [name(entity), detail(entity) ?? "", entity.id].joined(separator: " ").lowercased() }
}

struct LinkChip: Identifiable, Equatable {
    let id: UUID
    let entity: LinkEntity
    let source: LinkSource
}

/// One row of the Links view: an entity, everything linked to it, and what that reaches one more hop away.
struct LinkRow: Identifiable, Equatable {
    /// The entity's uuid; an agent nothing is linked to yet has none, and is identified by its `kind:id`.
    let id: String
    let entity: LinkEntity
    var chips: [LinkChip]
    var related: [LinkReach]
}

enum LinkRows {
    /// The rows for `mode`, by name: the entities of its kind with a link, and `including` (the agents, which can be linked by hand), narrowed
    /// by `query` against the row and its links.
    static func rows(_ table: LinkTable, mode: LinkMode, labels: LinkLabels, including: [LinkEntity] = [], query: String = "") -> [LinkRow] {
        let entities = Set(table.entities(kind: mode.kind) + including.filter { $0.kind == mode.kind })
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let rows = entities.map { entity -> LinkRow in
            let chips = table.neighbors(of: entity).compactMap { other in
                table.uuid(of: other).map { LinkChip(id: $0, entity: other, source: table.link(LinkPair(entity, other))?.source ?? .auto) }
            }
            let near = Set(chips.map(\.entity))
            return LinkRow(id: table.uuid(of: entity)?.uuidString ?? entity.key, entity: entity, chips: chips, related: table.related(to: entity, depth: 2).filter { !near.contains($0.entity) })
        }
        return rows.filter { row in
            let text = ([row.entity] + row.chips.map(\.entity)).map(labels.text).joined(separator: " ")
            return terms.allSatisfy(text.contains)
        }.sorted { labels.name($0.entity).localizedStandardCompare(labels.name($1.entity)) == .orderedAscending }
    }
}
