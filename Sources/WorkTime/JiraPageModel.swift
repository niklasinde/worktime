import AppKit
import SwiftUI

/// The tickets of the Jira page: the lists of every tab, cached in a file so the page opens at once, and fetched in the
/// background on the GitHub page's cadence. The credentials are the ones of `JiraModel`.
@MainActor
final class JiraPageModel: ObservableObject {
    static let shared = JiraPageModel()

    @Published var tab = JiraTab.assigned
    @Published var filter = JiraFilter()
    @Published private(set) var lists: [JiraTab: [JiraTicket]] = [:]
    @Published private(set) var fetched: Date?
    @Published private(set) var error: JiraError?
    @Published private(set) var refreshing = false
    @Published private(set) var pullRequests: [String: [GitHubPR]] = [:]
    @Published var notice: String?
    @Published private(set) var selected: String?
    @Published private(set) var details: [String: JiraDetail.State] = [:]
    private var detailFetched: [String: Date] = [:]

    let jira: JiraModel
    private let file: URL
    private var loop: Task<Void, Never>?
    private let noticeTimer = Debouncer()

    init(jira: JiraModel? = nil, file: URL = AppPaths.jiraTickets) {
        self.jira = jira ?? .shared
        self.file = file
        loadCache()
    }

    var configured: Bool { jira.configured }
    var site: String? { jira.site }
    var rows: [JiraTicket] { lists[tab] ?? [] }
    var mine: Set<String> { JiraTickets.mine(lists) }
    var visible: [JiraTicket] { JiraTickets.filter(rows, filter, mine: mine, now: Date()) }
    var statusCounts: [JiraStatusTab: Int] { JiraTickets.counts(rows, filter, mine: mine, now: Date()) }
    var options: JiraTickets.Options { JiraTickets.options(rows) }
    var hasData: Bool { lists.values.contains { !$0.isEmpty } }
    var isCapped: Bool { rows.count >= JiraTickets.pageSize }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(GitHubModel.shared.interval) * 60 * 1_000_000_000)
            }
        }
    }

    func loadCache() {
        guard let cache = JiraTickets.decode(try? Data(contentsOf: file)) else { return }
        lists = cache.lists
        fetched = cache.fetched
    }

    func refresh() async {
        guard configured, !refreshing, let client = jira.client() else { return }
        refreshing = true
        defer { refreshing = false }
        let fetch = await JiraTickets.fetchAll(client: client)
        error = fetch.error
        guard !fetch.lists.isEmpty else { return }
        lists = lists.merging(fetch.lists) { $1 }
        fetched = Date()
        linkPullRequests()
        save()
    }

    private func save() {
        guard let fetched else { return }
        let data = JiraTickets.encode(JiraTickets.Cache(fetched: fetched, lists: lists)), file = file
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The pull requests the GitHub page has cached, matched to tickets by the key in their title or head branch.
    func linkPullRequests() {
        let github = GitHubModel.shared
        let all = GitHubLogic.unique(github.prs) + github.watchedPRs
        pullRequests = JiraTickets.pullRequests(all) { github.store?.githubHeadBranch($0.url) }
    }

    func ticket(_ key: String) -> JiraTicket? { lists.values.joined().first { $0.key == key } }

    /// Shows the ticket in the detail pane at once, from the list's row, and fetches the whole issue behind it.
    func select(_ key: String?) {
        selected = key
        if let key { loadDetail(key) }
    }

    func loadDetail(_ key: String, force: Bool = false) {
        guard JiraDetail.needsFetch(fetchedAt: detailFetched[key], now: Date(), force: force) else { return }
        guard let client = jira.client() else {
            details[key] = .failed(.notConfigured)
            return
        }
        detailFetched[key] = Date()
        if case .loaded = details[key] {} else { details[key] = .loading }
        Task {
            let result = await Task.detached { () -> Result<JiraIssue, JiraError> in
                do { return .success(try await client.issue(key)) } catch { return .failure(JiraError.from(error)) }
            }.value
            switch result {
            case .success(let issue): details[key] = .loaded(issue)
            case .failure(let error):
                detailFetched[key] = nil
                if case .loaded = details[key] {} else { details[key] = .failed(error) }
            }
        }
    }

    func browseURL(_ key: String) -> URL? { site.flatMap { JiraLogic.browseURL(site: $0, key: key) } }

    func showNotice(_ text: String) {
        notice = text
        noticeTimer.schedule(after: 5) { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }

    // MARK: Agents

    /// The agent of a ticket from a typed key or pasted link; false when the text names no ticket.
    @discardableResult
    func openAgent(typed text: String) -> Bool {
        guard let key = JiraLogic.issueKey(text) else {
            showNotice("That is not a Jira ticket key or link")
            return false
        }
        openAgent(key: key)
        return true
    }

    /// Opens the ticket's agent, made the first time in the checkout of the repository a pull request naming the ticket is in
    /// (otherwise in a folder of its own) with the ticket and its pull requests waiting in the composer as the first prompt.
    func openAgent(key: String) {
        let store = TopicAgentStore.shared
        linkPullRequests()
        let linked = pullRequests[key] ?? [], known = ticket(key)
        if let known, TopicAgents.existing(jiraKey: key, in: store.topics) != nil {
            store.open(ticket: known)
            return
        }
        Task {
            let client = jira.client()
            let issue = await Task.detached { try? await client?.issue(key) }.value
            let ticket = known ?? issue.map(JiraAgents.ticket) ?? JiraTicket(key: key, summary: "", status: "", priority: nil, updated: nil)
            let folder = await Self.checkout(of: linked)
            guard let opened = store.open(ticket: ticket, folder: folder), opened.isNew, let issue else { return }
            let agent = store.load(opened.topic)
            let waiting = TopicAgents.prompt(opened.topic)
            guard agent.sessionID == nil, agent.draft.isEmpty || agent.draft == waiting else { return }
            agent.draft = JiraAgents.context(issue: issue, pullRequests: linked, site: site, now: Date())
        }
    }

    private nonisolated static func checkout(of prs: [GitHubPR]) async -> URL? {
        guard let repo = prs.first?.repo else { return nil }
        return await Task.detached { GitHubClaude.checkout(for: repo, under: GitHubClaudeModel.repositoriesRoot) }.value
    }

    func openLinkedPullRequest(_ pr: GitHubPR) {
        guard let target = GitHubLink.pullRequest(at: pr.url) else { return }
        GitHubModel.shared.showInWindow?(target)
    }

    #if DEBUG
    func showSample(lists: [JiraTab: [JiraTicket]], pullRequests: [String: [GitHubPR]] = [:], error: JiraError? = nil, fetched: Date? = Date()) {
        self.lists = lists
        self.pullRequests = pullRequests
        self.error = error
        self.fetched = fetched
        tab = .assigned
        filter = JiraFilter()
    }
    #endif
}
