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

/// One end of a link as callers name it, with its id normalized: a Jira key in upper case, a pull request as `owner/repo#12`, a branch as
/// `repo:branch`, a Slack thread as its permalink, an agent as its `AgentState.key`. The table resolves it to an entity uuid.
struct LinkEntity: Hashable, Codable, Comparable, Sendable {
    let kind: LinkKind
    let id: String

    init(kind: LinkKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// `kind:id`, the form the MCP tool uses.
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

/// A thing that can be linked, under a uuid that outlives a change of its natural id: `ref` is the id as `LinkEntity` writes it, `aliases`
/// the refs it had before (a Jira key after a move) that still resolve to it.
struct LinkEntityRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: LinkKind
    var ref: String
    var aliases: [String]
    var title: String?
    var createdAt: Date

    init(id: UUID = UUID(), kind: LinkKind, ref: String, aliases: [String] = [], title: String? = nil, createdAt: Date) {
        (self.id, self.kind, self.ref, self.aliases, self.title, self.createdAt) = (id, kind, ref, aliases, title, createdAt)
    }

    var entity: LinkEntity { LinkEntity(kind: kind, id: ref) }
}

/// The two ends of a link in canonical order, so that a pair has one key whichever end is named first.
struct LinkEnds: Hashable, Sendable {
    let from: UUID
    let to: UUID

    init(_ first: UUID, _ second: UUID) {
        (from, to) = first.uuidString <= second.uuidString ? (first, second) : (second, first)
    }
}

/// A link between two entities. Links are undirected: the pair is stored once, the smaller uuid as `fromEntity`.
struct LinkRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var fromEntity: UUID
    var toEntity: UUID
    var source: LinkSource
    /// A removal by the user: the row stays so that auto-linking does not add the link again.
    var removed: Bool
    var createdAt: Date
    var lastSeenAt: Date

    init(id: UUID = UUID(), ends: LinkEnds, source: LinkSource, removed: Bool = false, createdAt: Date, lastSeenAt: Date? = nil) {
        (self.id, fromEntity, toEntity, self.source, self.removed, self.createdAt) = (id, ends.from, ends.to, source, removed, createdAt)
        self.lastSeenAt = lastSeenAt ?? createdAt
    }

    var ends: LinkEnds { LinkEnds(fromEntity, toEntity) }

    func other(than entity: UUID) -> UUID? {
        if fromEntity == entity { return toEntity }
        return toEntity == entity ? fromEntity : nil
    }

    func repointed(from old: UUID, to new: UUID) -> LinkRecord {
        LinkRecord(id: id, ends: LinkEnds(fromEntity == old ? new : fromEntity, toEntity == old ? new : toEntity),
                   source: source, removed: removed, createdAt: createdAt, lastSeenAt: lastSeenAt)
    }

    /// The same pair seen twice: a manual link beats an auto one, and between two manual ones a removal only holds when both are removals.
    func merged(with other: LinkRecord) -> LinkRecord {
        var winner = self
        if source != other.source {
            winner = source == .manual ? self : other
        } else if source == .manual {
            winner.removed = removed && other.removed
        }
        winner.createdAt = min(createdAt, other.createdAt)
        winner.lastSeenAt = max(lastSeenAt, other.lastSeenAt)
        return winner
    }
}

/// An entity reached from another through links.
struct LinkReach: Equatable, Identifiable, Sendable {
    let id: UUID
    let entity: LinkEntity
    let depth: Int
    /// The entity it was reached through: the start itself at depth 1.
    let via: LinkEntity
}

/// Every link between agents, tickets, pull requests and the rest, as entities and links under uuids. Callers name things by `LinkEntity`
/// (kind and natural id, an alias included) and the table resolves them. Status (a ticket Done, a pull request merged) is not kept here.
struct LinkTable: Equatable, Sendable {
    /// Links that nothing has confirmed for this long are dropped, unless the user made them or removed them.
    static let staleAfter: TimeInterval = 90 * 86400
    /// How old a link's `lastSeenAt` is allowed to get before a sighting touches it, so a steady table does not change.
    static let touchAfter: TimeInterval = 86400

    private(set) var entities: [UUID: LinkEntityRecord] = [:]
    private(set) var links: [UUID: LinkRecord] = [:]
    private var byRef: [LinkEntity: UUID] = [:]
    private var byEnds: [LinkEnds: UUID] = [:]
    private var adjacent: [UUID: Set<UUID>] = [:]

    init(entities: [LinkEntityRecord] = [], links: [LinkRecord] = []) {
        self.entities = Dictionary(entities.map { ($0.id, $0) }) { first, _ in first }
        var byEnds: [LinkEnds: LinkRecord] = [:]
        for link in links where self.entities[link.fromEntity] != nil && self.entities[link.toEntity] != nil && link.fromEntity != link.toEntity {
            byEnds[link.ends] = byEnds[link.ends].map { $0.merged(with: link) } ?? link
        }
        self.links = Dictionary(byEnds.values.map { ($0.id, $0) }) { first, _ in first }
        reindex()
    }

    static func == (lhs: LinkTable, rhs: LinkTable) -> Bool { lhs.entities == rhs.entities && lhs.links == rhs.links }

    var allLinks: [LinkRecord] { links.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    var allEntities: [LinkEntityRecord] { entities.values.sorted { $0.id.uuidString < $1.id.uuidString } }
    var active: [LinkRecord] { allLinks.filter { !$0.removed } }

    private mutating func reindex() {
        byRef = [:]
        byEnds = [:]
        adjacent = [:]
        for record in entities.values {
            byRef[record.entity] = record.id
            for alias in record.aliases { byRef[LinkEntity(kind: record.kind, id: alias)] = record.id }
        }
        for link in links.values { index(link) }
    }

    private mutating func index(_ link: LinkRecord) {
        byEnds[link.ends] = link.id
        adjacent[link.fromEntity, default: []].insert(link.id)
        adjacent[link.toEntity, default: []].insert(link.id)
    }

    func uuid(of entity: LinkEntity) -> UUID? { byRef[entity] }

    func entity(id: UUID) -> LinkEntity? { entities[id]?.entity }

    func record(_ entity: LinkEntity) -> LinkEntityRecord? { uuid(of: entity).flatMap { entities[$0] } }

    func link(_ pair: LinkPair) -> LinkRecord? {
        guard let first = uuid(of: pair.first), let second = uuid(of: pair.second) else { return nil }
        return byEnds[LinkEnds(first, second)].flatMap { links[$0] }
    }

    private mutating func ensure(_ entity: LinkEntity, now: Date) -> UUID {
        if let id = byRef[entity] { return id }
        let record = LinkEntityRecord(kind: entity.kind, ref: entity.id, createdAt: now)
        entities[record.id] = record
        byRef[entity] = record.id
        return record.id
    }

    /// The ends of `pair` as uuids, creating the entities; nil for a pair of one thing.
    private mutating func ends(of pair: LinkPair, now: Date) -> LinkEnds? {
        guard pair.first != pair.second else { return nil }
        let first = ensure(pair.first, now: now)
        let second = ensure(pair.second, now: now)
        return first == second ? nil : LinkEnds(first, second)
    }

    /// Adds a link, or confirms it. A manual link wins over an auto one and revives a removed one; an auto sighting never revives a removal.
    /// True when the table changed.
    @discardableResult
    mutating func upsert(_ pair: LinkPair, source: LinkSource, now: Date) -> Bool {
        guard let ends = ends(of: pair, now: now) else { return false }
        guard var link = byEnds[ends].flatMap({ links[$0] }) else {
            store(LinkRecord(ends: ends, source: source, createdAt: now))
            return true
        }
        let before = link
        if source == .manual {
            link.source = .manual
            link.removed = false
            link.lastSeenAt = now
        } else if !link.removed, now.timeIntervalSince(link.lastSeenAt) >= Self.touchAfter {
            link.lastSeenAt = now
        }
        guard link != before else { return false }
        store(link)
        return true
    }

    /// A removal is kept as a manual row marked `removed`, so that auto-linking does not bring the link back.
    mutating func remove(_ pair: LinkPair, now: Date) {
        guard let ends = ends(of: pair, now: now) else { return }
        var link = byEnds[ends].flatMap { links[$0] } ?? LinkRecord(ends: ends, source: .manual, createdAt: now)
        link.source = .manual
        link.removed = true
        link.lastSeenAt = now
        store(link)
    }

    private mutating func store(_ link: LinkRecord) {
        links[link.id] = link
        index(link)
    }

    mutating func ingest(_ pairs: [LinkPair], now: Date) {
        for pair in pairs { upsert(pair, source: .auto, now: now) }
    }

    /// Gives `entity` a new natural id and keeps the old one as an alias, so a link written under either still finds it. When the new id
    /// already names another entity the two become one: that one stays, takes over the links and the aliases of the renamed one, and a pair
    /// linked twice ends up as one link, the manual one winning. False when nothing changed.
    @discardableResult
    mutating func rename(_ entity: LinkEntity, to ref: String) -> Bool {
        guard let id = uuid(of: entity), var record = entities[id], record.ref != ref else { return false }
        guard let survivorID = byRef[LinkEntity(kind: record.kind, id: ref)], survivorID != id else {
            record.aliases = Self.aliases(record.aliases + [record.ref], without: ref)
            record.ref = ref
            entities[id] = record
            reindex()
            return true
        }
        var survivor = entities[survivorID]!
        survivor.aliases = Self.aliases(survivor.aliases + record.aliases + [record.ref], without: survivor.ref)
        survivor.title = survivor.title ?? record.title
        survivor.createdAt = min(survivor.createdAt, record.createdAt)
        entities[survivorID] = survivor
        entities[id] = nil
        self = LinkTable(entities: Array(entities.values), links: links.values.map { $0.repointed(from: id, to: survivorID) })
        return true
    }

    private static func aliases(_ aliases: [String], without ref: String) -> [String] {
        var seen = Set<String>()
        return aliases.filter { $0 != ref && seen.insert($0).inserted }
    }

    /// Without the auto links nothing confirmed lately, and the entities left with no link.
    func pruned(now: Date) -> LinkTable {
        let kept = allLinks.filter { $0.source == .manual || $0.removed || now.timeIntervalSince($0.lastSeenAt) < Self.staleAfter }
        let used = Set(kept.flatMap { [$0.fromEntity, $0.toEntity] })
        return LinkTable(entities: allEntities.filter { used.contains($0.id) }, links: kept)
    }

    private func neighborIDs(of id: UUID) -> [UUID] {
        (adjacent[id] ?? []).compactMap { links[$0] }.filter { !$0.removed }.compactMap { $0.other(than: id) }
    }

    /// The other end of every link touching `entity`, of one kind when given, in a stable order.
    func neighbors(of entity: LinkEntity, kind: LinkKind? = nil) -> [LinkEntity] {
        guard let id = uuid(of: entity) else { return [] }
        return neighborIDs(of: id).compactMap { entities[$0]?.entity }.filter { kind == nil || $0.kind == kind }.sorted()
    }

    /// The entities of one kind with at least one link.
    func entities(kind: LinkKind) -> [LinkEntity] {
        entities.values.filter { $0.kind == kind && !neighborIDs(of: $0.id).isEmpty }.map(\.entity).sorted()
    }

    /// What `entity` reaches in up to `depth` hops, nearest first: an agent's ticket, then the ticket's other pull requests. Each entity
    /// is reported once, at its shortest distance, and the start never.
    func related(to start: LinkEntity, depth: Int) -> [LinkReach] {
        guard let startID = uuid(of: start) else { return [] }
        var seen: Set<UUID> = [startID]
        var frontier = [startID]
        var reached: [LinkReach] = []
        for level in 1...max(depth, 1) {
            var next: [UUID] = []
            for id in frontier {
                let via = entities[id]!.entity
                for other in neighborIDs(of: id).sorted(by: { entities[$0]!.entity < entities[$1]!.entity }) where seen.insert(other).inserted {
                    reached.append(LinkReach(id: other, entity: entities[other]!.entity, depth: level, via: via))
                    next.append(other)
                }
            }
            frontier = next
        }
        return reached
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
