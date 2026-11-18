import Combine
import Foundation

/// The link table on disk next to the other stores: a corrupt or missing file is an empty table, writes are atomic and stale auto links are dropped.
@MainActor
final class LinkStore: ObservableObject {
    static let shared = LinkStore(file: AppPaths.links)

    @Published private(set) var table: LinkTable
    private static let writer = DispatchQueue(label: "worktime.links.write", qos: .utility)
    private let file: URL?

    init(file: URL?, now: Date = Date()) {
        self.file = file
        table = LinkTables.decode(file.flatMap { try? Data(contentsOf: $0) }).pruned(now: now)
    }

    func ingest(_ pairs: [LinkPair], now: Date = Date()) {
        update { $0.ingest(pairs, now: now) }
    }

    func add(_ pair: LinkPair, now: Date = Date()) {
        update { $0.upsert(pair, source: .manual, now: now) }
    }

    func remove(_ pair: LinkPair, now: Date = Date()) {
        update { $0.remove(pair, now: now) }
    }

    private func update(_ change: (inout LinkTable) -> Void) {
        var next = table
        change(&next)
        guard next != table else { return }
        table = next
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
