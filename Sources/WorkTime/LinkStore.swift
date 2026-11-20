import Combine
import Foundation

/// The link table on disk next to the other stores: a corrupt or missing file is an empty table, writes are atomic, stale auto links are
/// dropped and a file in the first format is converted once, its original kept as `links.v1.json`.
@MainActor
final class LinkStore: ObservableObject {
    static let shared = LinkStore(file: AppPaths.links)

    @Published private(set) var table: LinkTable
    private(set) var searchIndex: AgentLinkIndex
    private static let writer = DispatchQueue(label: "worktime.links.write", qos: .utility)
    private let file: URL?

    init(file: URL?, now: Date = Date()) {
        self.file = file
        let data = file.flatMap { try? Data(contentsOf: $0) }
        let loaded = LinkTables.load(data)
        let pruned = loaded.table.pruned(now: now)
        table = pruned
        searchIndex = AgentLinkIndex(table: pruned)
        if loaded.migrated, let file, let data {
            try? data.write(to: file.deletingLastPathComponent().appendingPathComponent(LinkTables.backupName), options: .atomic)
            LinkTables.encode(table).map { try? $0.write(to: file, options: .atomic) }
        }
    }

    func ingest(_ pairs: [LinkPair], now: Date = Date()) {
        update { $0.ingest(pairs, now: now) }
    }

    func link(agent key: String, to targets: [LinkEntity]) {
        guard !targets.isEmpty else { return }
        update { table in
            for target in Set(targets) where target != .agent(key) {
                let pair = LinkPair(.agent(key), target)
                guard table.link(pair)?.source != .manual else { continue }
                table.upsert(pair, source: .manual, now: Date())
            }
        }
    }

    func add(_ pair: LinkPair, now: Date = Date()) {
        update { $0.upsert(pair, source: .manual, now: now) }
    }

    func remove(_ pair: LinkPair, now: Date = Date()) {
        update { $0.remove(pair, now: now) }
    }

    /// A new natural id for an entity, the old one kept as an alias: a Jira key after a move, a repository after a transfer.
    func rename(_ entity: LinkEntity, to ref: String) {
        update { $0.rename(entity, to: ref) }
    }

    private func update(_ change: (inout LinkTable) -> Void) {
        var next = table
        change(&next)
        guard next != table else { return }
        table = next
        searchIndex = AgentLinkIndex(table: next)
        save()
    }

    private func save() {
        guard let file, let data = LinkTables.encode(table) else { return }
        Self.writer.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
