import Foundation

/// Looks up the titles and states of the tickets and pull requests in the Related lists: for the rows on screen only, batched, one
/// lookup at a time per ticket or pull request, kept on disk, and not repeated for a while after a failure.
@MainActor
final class SessionRefDirectory: ObservableObject {
    static let shared = SessionRefDirectory(file: AppPaths.sessionRefTitles)

    @Published private(set) var entries: [String: SessionRefEntry]
    @Published private(set) var loading: Set<String> = []
    private var backoff: [String: Date] = [:]
    private let file: URL?

    init(file: URL?) {
        self.file = file
        entries = SessionRefLookup.decode(file.flatMap { try? Data(contentsOf: $0) })
    }

    /// Fetches what the rows need and the app does not already have; `skip` holds the keys that need nothing.
    func ensure(_ refs: [SessionRef], skip: Set<String>, now: Date = Date()) async {
        let plan = SessionRefLookup.plan(refs, skip: skip, cache: entries, backoff: backoff, inFlight: loading, now: now)
        guard !plan.isEmpty else { return }
        loading.formUnion(plan.ids)
        async let tickets: Void = lookUp(tickets: plan.tickets)
        async let pullRequests: Void = lookUp(pullRequests: plan.pullRequests)
        _ = await (tickets, pullRequests)
        save()
    }

    private func lookUp(tickets batches: [[String]]) async {
        for keys in batches {
            let ids = keys.map { SessionRef.jira($0).cacheKey }
            let result = await Task.detached(priority: .utility) { () -> Result<[JiraTicket], JiraError>? in
                guard let access = MCPServer.storedJira() else { return nil }
                do { return .success(try await access.client.search(jql: SessionRefLookup.jql(keys), max: keys.count, fields: ["summary", "status"]).tickets) } catch {
                    return .failure(JiraError.from(error))
                }
            }.value
            switch result {
            case .success(let found)?: finish(ids, with: SessionRefLookup.entries(forTickets: keys, found: found, now: Date()))
            case .failure?: fail(ids, unconfigured: false)
            case nil: fail(ids, unconfigured: true)
            }
        }
    }

    private func lookUp(pullRequests batches: [[GitHubLink.Target]]) async {
        for targets in batches {
            let ids = targets.map { SessionRef.pullRequest(repo: $0.repo, number: $0.number).cacheKey }
            let urls = targets.map(\.url)
            let cli = GitHubLogic.findCLI()
            let found = await Task.detached(priority: .utility) { GitHubClient.fetchLookup(cli: cli, urls: urls) }.value
            if let found { finish(ids, with: SessionRefLookup.entries(forPullRequests: targets, found: found, now: Date())) } else { fail(ids, unconfigured: cli == nil) }
        }
    }

    private func finish(_ ids: [String], with answers: [String: SessionRefEntry]) {
        let merged = entries.merging(answers) { _, new in new }
        if merged != entries { entries = merged }
        loading.subtract(ids)
        for id in ids { backoff[id] = nil }
    }

    private func fail(_ ids: [String], unconfigured: Bool) {
        let until = SessionRefLookup.retryAfter(unconfigured: unconfigured, now: Date())
        for id in ids { backoff[id] = until }
        loading.subtract(ids)
    }

    private func save() {
        guard let file else { return }
        let data = SessionRefLookup.encode(entries)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
