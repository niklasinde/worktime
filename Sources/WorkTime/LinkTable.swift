import Foundation

/// What an end of a link is: an open string, so a new kind needs no migration.
struct LinkKind: RawRepresentable, Hashable, Codable, Comparable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let agent = LinkKind(rawValue: "agent")
    static let jira = LinkKind(rawValue: "jira")
    static let githubPR = LinkKind(rawValue: "github_pr")
    static let branch = LinkKind(rawValue: "branch")
    static let slackThread = LinkKind(rawValue: "slack_thread")
    static let meeting = LinkKind(rawValue: "meeting")
    static let confluence = LinkKind(rawValue: "confluence")
    static let commit = LinkKind(rawValue: "commit")
    static let known: [LinkKind] = [.agent, .jira, .githubPR, .branch, .slackThread, .meeting, .confluence, .commit]

    private var order: Int { Self.known.firstIndex(of: self) ?? Self.known.count }

    static func < (lhs: LinkKind, rhs: LinkKind) -> Bool { (lhs.order, lhs.rawValue) < (rhs.order, rhs.rawValue) }
}

enum LinkSource: String, Codable, Sendable {
    case auto, manual
}

/// One end of a link, with its id normalized: a Jira key in upper case, a pull request as `owner/repo#12`, a branch as `repo:branch`,
/// a Slack thread as its permalink, an agent as its `AgentState.key`.
struct LinkEntity: Hashable, Codable, Comparable, Sendable {
    let kind: LinkKind
    let id: String

    init(kind: LinkKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// `kind:id`, the form the MCP tool and the view's ids use.
    var key: String { "\(kind.rawValue):\(id)" }

    init?(key: String) {
        guard let colon = key.firstIndex(of: ":"), colon != key.startIndex, key.index(after: colon) != key.endIndex else { return nil }
        self.init(kind: LinkKind(rawValue: String(key[..<colon])), id: String(key[key.index(after: colon)...]))
    }

    static func < (lhs: LinkEntity, rhs: LinkEntity) -> Bool { (lhs.kind, lhs.id) < (rhs.kind, rhs.id) }

    static func agent(_ key: String) -> LinkEntity { LinkEntity(kind: .agent, id: key) }
    static func jira(_ key: String) -> LinkEntity { LinkEntity(kind: .jira, id: key.uppercased()) }
    static func pullRequest(_ target: GitHubLink.Target) -> LinkEntity { LinkEntity(kind: .githubPR, id: "\(target.repo)#\(target.number)") }
    static func branch(_ id: String) -> LinkEntity { LinkEntity(kind: .branch, id: id) }
    static func slack(_ permalink: String) -> LinkEntity { LinkEntity(kind: .slackThread, id: permalink) }
}

/// Two entities that belong together, in no particular order.
struct LinkPair: Hashable, Sendable {
    let first: LinkEntity
    let second: LinkEntity

    init(_ first: LinkEntity, _ second: LinkEntity) {
        self.first = first
        self.second = second
    }
}

/// A link between two entities. Links are undirected: the pair is stored once, the smaller end as `from`.
struct LinkEdge: Codable, Equatable, Identifiable, Sendable {
    var fromKind: LinkKind
    var fromID: String
    var toKind: LinkKind
    var toID: String
    var source: LinkSource
    /// A removal by the user: the row stays so that auto-linking does not add the link again.
    var removed: Bool
    var createdAt: Date
    var lastSeenAt: Date

    init(_ pair: LinkPair, source: LinkSource, removed: Bool = false, now: Date) {
        let (from, to) = pair.first <= pair.second ? (pair.first, pair.second) : (pair.second, pair.first)
        (fromKind, fromID, toKind, toID) = (from.kind, from.id, to.kind, to.id)
        (self.source, self.removed, createdAt, lastSeenAt) = (source, removed, now, now)
    }

    var from: LinkEntity { LinkEntity(kind: fromKind, id: fromID) }
    var to: LinkEntity { LinkEntity(kind: toKind, id: toID) }
    var id: String { from.key + "|" + to.key }

    func other(than entity: LinkEntity) -> LinkEntity? {
        if from == entity { return to }
        return to == entity ? from : nil
    }

    static func id(_ pair: LinkPair) -> String { LinkEdge(pair, source: .auto, now: .distantPast).id }
}

/// An entity reached from another through links.
struct LinkReach: Equatable, Sendable {
    let entity: LinkEntity
    let depth: Int
    /// The entity it was reached through: the start itself at depth 1.
    let via: LinkEntity
}

/// Every link between agents, tickets, pull requests and the rest. Status (a ticket Done, a pull request merged) is not kept here.
struct LinkTable: Equatable, Sendable {
    /// Links that nothing has confirmed for this long are dropped, unless the user made them or removed them.
    static let staleAfter: TimeInterval = 90 * 86400
    /// How old a link's `lastSeenAt` is allowed to get before a sighting touches it, so a steady table does not change.
    static let touchAfter: TimeInterval = 86400

    private(set) var edges: [String: LinkEdge] = [:]
    private var adjacent: [LinkEntity: Set<String>] = [:]

    init(edges: [LinkEdge] = []) {
        for edge in edges { store(edge) }
    }

    var all: [LinkEdge] { edges.values.sorted { $0.id < $1.id } }
    var active: [LinkEdge] { all.filter { !$0.removed } }

    func edge(_ pair: LinkPair) -> LinkEdge? { edges[LinkEdge.id(pair)] }

    private mutating func store(_ edge: LinkEdge) {
        edges[edge.id] = edge
        adjacent[edge.from, default: []].insert(edge.id)
        adjacent[edge.to, default: []].insert(edge.id)
    }

    private mutating func drop(_ id: String) {
        guard let edge = edges.removeValue(forKey: id) else { return }
        for end in [edge.from, edge.to] {
            adjacent[end]?.remove(id)
            if adjacent[end]?.isEmpty == true { adjacent[end] = nil }
        }
    }

    /// Adds a link, or confirms it. A manual link wins over an auto one and revives a removed one; an auto sighting never revives a removal.
    /// True when the table changed.
    @discardableResult
    mutating func upsert(_ pair: LinkPair, source: LinkSource, now: Date) -> Bool {
        guard pair.first != pair.second else { return false }
        guard var edge = edge(pair) else {
            store(LinkEdge(pair, source: source, now: now))
            return true
        }
        let before = edge
        if source == .manual {
            edge.source = .manual
            edge.removed = false
            edge.lastSeenAt = now
        } else if !edge.removed, now.timeIntervalSince(edge.lastSeenAt) >= Self.touchAfter {
            edge.lastSeenAt = now
        }
        guard edge != before else { return false }
        store(edge)
        return true
    }

    /// A removal is kept as a manual row marked `removed`, so that auto-linking does not bring the link back.
    mutating func remove(_ pair: LinkPair, now: Date) {
        guard pair.first != pair.second else { return }
        var edge = self.edge(pair) ?? LinkEdge(pair, source: .manual, now: now)
        edge.source = .manual
        edge.removed = true
        edge.lastSeenAt = now
        store(edge)
    }

    mutating func ingest(_ pairs: [LinkPair], now: Date) {
        for pair in pairs { upsert(pair, source: .auto, now: now) }
    }

    func pruned(now: Date) -> LinkTable {
        LinkTable(edges: all.filter { $0.source == .manual || $0.removed || now.timeIntervalSince($0.lastSeenAt) < Self.staleAfter })
    }

    /// The other end of every link touching `entity`, of one kind when given, in a stable order.
    func neighbors(of entity: LinkEntity, kind: LinkKind? = nil) -> [LinkEntity] {
        (adjacent[entity] ?? []).compactMap { edges[$0] }
            .filter { !$0.removed }
            .compactMap { $0.other(than: entity) }
            .filter { kind == nil || $0.kind == kind }
            .sorted()
    }

    /// The entities of one kind with at least one link.
    func entities(kind: LinkKind) -> [LinkEntity] {
        adjacent.keys.filter { $0.kind == kind && !neighbors(of: $0).isEmpty }.sorted()
    }

    /// What `entity` reaches in up to `depth` hops, nearest first: an agent's ticket, then the ticket's other pull requests. Each entity
    /// is reported once, at its shortest distance, and the start never.
    func related(to start: LinkEntity, depth: Int) -> [LinkReach] {
        var seen: Set<LinkEntity> = [start]
        var frontier = [start]
        var reached: [LinkReach] = []
        for level in 1...max(depth, 1) {
            var next: [LinkEntity] = []
            for entity in frontier {
                for other in neighbors(of: entity) where seen.insert(other).inserted {
                    reached.append(LinkReach(entity: other, depth: level, via: entity))
                    next.append(other)
                }
            }
            frontier = next
        }
        return reached
    }
}

/// The table as the file the app keeps and the MCP server reads.
enum LinkTables {
    static let fileName = "links.json"
    static let version = 1

    struct File: Codable, Equatable {
        var version = LinkTables.version
        var edges: [LinkEdge]
    }

    static func encode(_ table: LinkTable) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(File(edges: table.all))
    }

    /// An empty table for a missing or corrupt file.
    static func decode(_ data: Data?) -> LinkTable {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.flatMap { try? decoder.decode(File.self, from: $0) }.map { LinkTable(edges: $0.edges) } ?? LinkTable()
    }
}

/// Writing a thing down the one way the table keeps it.
enum LinkTargets {
    static func jira(_ text: String) -> LinkEntity? { JiraLogic.issueKey(text).map(LinkEntity.jira) }

    static func pullRequest(_ text: String) -> LinkEntity? { GitHubLink.pasted(text).map(LinkEntity.pullRequest) }

    static func branch(repo: String, name: String) -> LinkEntity? {
        let short = repo.split(separator: "/").last.map(String.init) ?? repo
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty || name.isEmpty ? nil : .branch("\(short):\(name)")
    }

    static func slack(_ text: String) -> LinkEntity? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: text)?.host?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com") else { return nil }
        return .slack(text)
    }

    /// What a pasted text names: a pull request, a Slack thread or a Jira ticket.
    static func entity(from text: String) -> LinkEntity? { pullRequest(text) ?? slack(text) ?? jira(text) }

    /// A bare Jira key or pull request address as `jira:KEY`, or the `kind:id` the table uses.
    static func parse(_ text: String) -> LinkEntity? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = LinkEntity(key: text), LinkKind.known.contains(known.kind) {
            switch known.kind {
            case .jira: return jira(known.id)
            case .githubPR: return pullRequest(known.id) ?? known
            default: return known
            }
        }
        return entity(from: text)
    }

    /// The pull request's address from its id.
    static func pullRequestURL(_ id: String) -> String? { GitHubLink.pasted(id)?.url }
}
