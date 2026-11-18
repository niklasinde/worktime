import Foundation

/// The table as the file the app keeps and the MCP server reads: entities and links under uuids. The first version stored one row per
/// link with both natural ids in it; that file still reads, and the app converts it once.
enum LinkTables {
    static let fileName = "links.json"
    static let backupName = "links.v1.json"
    static let version = 2

    struct File: Codable, Equatable {
        var version = LinkTables.version
        var entities: [LinkEntityRecord]
        var links: [LinkRecord]
    }

    struct LegacyEdge: Codable, Equatable {
        var fromKind: LinkKind
        var fromID: String
        var toKind: LinkKind
        var toID: String
        var source: LinkSource
        var removed: Bool
        var createdAt: Date
        var lastSeenAt: Date
    }

    struct LegacyFile: Codable, Equatable {
        var version: Int
        var edges: [LegacyEdge]
    }

    static func encode(_ table: LinkTable) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try? encoder.encode(File(entities: table.allEntities, links: table.allLinks))
    }

    /// The table in `data` and whether it was the first version: an empty table for a missing or corrupt file.
    static func load(_ data: Data?) -> (table: LinkTable, migrated: Bool) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data else { return (LinkTable(), false) }
        if let file = try? decoder.decode(File.self, from: data) { return (LinkTable(entities: file.entities, links: file.links), false) }
        if let legacy = try? decoder.decode(LegacyFile.self, from: data) { return (migrate(legacy.edges), true) }
        return (LinkTable(), false)
    }

    static func decode(_ data: Data?) -> LinkTable { load(data).table }

    /// One entity per distinct end, one link per edge with its source, removal and dates kept.
    static func migrate(_ edges: [LegacyEdge]) -> LinkTable {
        var entities: [LinkEntity: LinkEntityRecord] = [:]
        func id(_ kind: LinkKind, _ ref: String, createdAt: Date) -> UUID {
            let entity = LinkEntity(kind: kind, id: ref)
            if let existing = entities[entity] { return existing.id }
            let record = LinkEntityRecord(kind: kind, ref: ref, createdAt: createdAt)
            entities[entity] = record
            return record.id
        }
        let ordered = edges.sorted { ($0.fromKind, $0.fromID, $0.toKind, $0.toID) < ($1.fromKind, $1.fromID, $1.toKind, $1.toID) }
        let links = ordered.map { edge in
            LinkRecord(ends: LinkEnds(id(edge.fromKind, edge.fromID, createdAt: edge.createdAt), id(edge.toKind, edge.toID, createdAt: edge.createdAt)),
                       source: edge.source, removed: edge.removed, createdAt: edge.createdAt, lastSeenAt: edge.lastSeenAt)
        }
        return LinkTable(entities: Array(entities.values), links: links)
    }
}
