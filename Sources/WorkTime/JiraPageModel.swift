import AppKit
import SwiftUI

/// The tickets of the Jira page: the lists of every tab, cached in a file so the page opens at once, and fetched in the
/// background on the GitHub page's cadence. The credentials are the ones of `JiraModel`.
@MainActor
final class JiraPageModel: ObservableObject {
    static let shared = JiraPageModel()

    @Published var tab = JiraTab.assigned { didSet { if tab != oldValue { filtersChanged() } } }
    @Published var filter = JiraFilter() { didSet { if filter != oldValue { filtersChanged(textOnly: filter.withoutText == oldValue.withoutText) } } }
    @Published private(set) var lists: [JiraTab: [JiraTicket]] = [:]
    @Published private(set) var results: [String: QueryResult] = [:]
    @Published private(set) var querying = false
    @Published private var rawJQL: String?
    @Published private(set) var queryError: JiraError?
    @Published private(set) var savedViews: [JiraSavedView] = []
    @Published private(set) var people: [String: String] = [:]
    @Published private(set) var transitions: [String: [JiraTransition]] = [:]
    @Published private(set) var transitionErrors: [String: JiraError] = [:]
    @Published private(set) var loadingTransitions: Set<String> = []
    @Published private(set) var undo: Undo?
    @Published var statusPicker: String?
    @Published var assignPicker: String?
    @Published var drafts: [String: String] = [:]
    @Published private(set) var fetched: Date?
    @Published private(set) var error: JiraError?
    @Published private(set) var refreshing = false
    @Published private(set) var pullRequests: [String: [GitHubPR]] = [:]
    @Published var notice: String?
    @Published private(set) var selected: String?
    @Published private(set) var details: [String: JiraDetail.State] = [:]
    private var detailFetched: [String: Date] = [:]
    private var transitionFetched: [String: Date] = [:]
    private var myself: JiraPerson?
    private var queryTask: Task<Void, Never>?
    private var persisting = true

    /// The tickets a query returned, shown at once the next time the same query is asked for and fetched again behind them.
    struct QueryResult: Equatable {
        var tickets: [JiraTicket]
        var fetched: Date
    }

    /// The move just made, which can be taken back while Jira offers a way back to where the ticket was.
    struct Undo: Equatable {
        let key: String
        let from: String
        let text: String
        var transition: JiraTransition?
    }

    static let queryFreshFor: TimeInterval = 20
    static let keptQueries = 20
    static let transitionsFreshFor: TimeInterval = 120
    static let undoSeconds: TimeInterval = 10
    private static let peopleKey = "jiraKnownPeople"

    let jira: JiraModel
    private let file: URL
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private let noticeTimer = Debouncer()
    private let undoTimer = Debouncer()

    init(jira: JiraModel? = nil, file: URL = AppPaths.jiraTickets, defaults: UserDefaults = .standard) {
        self.jira = jira ?? .shared
        self.file = file
        self.defaults = defaults
        loadCache()
        if let state = JiraPageState.decode(defaults.data(forKey: JiraSavedViews.pageStateKey)) {
            tab = state.tab
            filter = state.filter
        }
        savedViews = JiraSavedViews.decode(defaults.data(forKey: JiraSavedViews.key))
        people = (defaults.dictionary(forKey: Self.peopleKey) as? [String: String]) ?? [:]
        learnPeople(lists.values.joined())
    }

    var configured: Bool { jira.configured }
    var site: String? { jira.site }
    var baseRows: [JiraTicket] { lists[tab] ?? [] }
    var mine: Set<String> { JiraTickets.mine(lists) }
    var isRaw: Bool { JiraQuery.isRaw(filter.query) }
    var hasData: Bool { lists.values.contains { !$0.isEmpty } }
    var isCapped: Bool { rows.count >= JiraTickets.pageSize }

    /// The query the list is fetched with, nil while the tab's cached list answers.
    var activeJQL: String? {
        if isRaw { return rawJQL }
        return JiraQuery.needsServer(filter) ? JiraQuery.jql(tab, filter) : nil
    }

    /// Whether the rows are what a query returned, rather than the tab's list or what of it the filters leave while the query runs.
    var served: Bool { activeJQL.flatMap { results[$0] } != nil }

    var rows: [JiraTicket] {
        guard let jql = activeJQL else { return isRaw ? [] : baseRows }
        if let result = results[jql] { return result.tickets }
        return isRaw || filter.assignee != nil ? [] : JiraTickets.filter(baseRows, filter.withoutText, mine: mine, now: Date())
    }

    /// The rows the chips and the search text narrow further; the query has applied the other filters when it answered.
    private var shown: JiraFilter {
        var shown = served ? filter.withoutRefinements : filter
        if isRaw { shown.query = "" }
        return shown
    }

    var visible: [JiraTicket] { JiraTickets.filter(rows, shown, mine: mine, now: Date()) }
    var statusCounts: [JiraStatusTab: Int] { JiraTickets.counts(rows, shown, mine: mine, now: Date()) }
    var options: JiraTickets.Options { JiraTickets.options(baseRows + rows).including(filter) }
    var title: String { JiraQuery.title(count: visible.count, capped: isCapped, tab: tab, filter: filter) }

    var projectChoices: [String] {
        JiraQuery.projectChoices(configured: WorkspaceStore.shared.workspaces.flatMap(\.jiraProjects), seen: options.projects, selected: filter.project)
    }

    /// The people the assignee menu offers: those on the tickets shown and those picked before, by name.
    var assigneeChoices: [JiraPerson] {
        var all = Dictionary(uniqueKeysWithValues: people.map { ($0.key, $0.value) })
        JiraTickets.people(baseRows + rows).forEach { all[$0.id] = $0.name }
        return all.map { JiraPerson(id: $0.key, name: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

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
        defer { requery(force: true) }
        guard !fetch.lists.isEmpty else { return }
        lists = lists.merging(fetch.lists) { $1 }
        fetched = Date()
        learnPeople(lists.values.joined())
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

    func ticket(_ key: String) -> JiraTicket? {
        lists.values.joined().first { $0.key == key } ?? results.values.lazy.flatMap(\.tickets).first { $0.key == key }
    }

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

    // MARK: Filters

    private func filtersChanged(textOnly: Bool = false) {
        if textOnly, isRaw { return }
        if !textOnly { persistState() }
        if !isRaw { rawJQL = nil }
        if activeJQL == nil {
            queryTask?.cancel()
            querying = false
            queryError = nil
        } else {
            requery()
        }
    }

    /// Runs the query typed after `jql:`, which the search field does when Return is pressed.
    func runRaw() {
        guard let query = JiraQuery.raw(filter.query) else { return }
        rawJQL = query
        requery(force: true)
    }

    func requery(force: Bool = false) {
        guard configured, let jql = activeJQL, let client = jira.client() else { return }
        if !force, let cached = results[jql], Date().timeIntervalSince(cached.fetched) < Self.queryFreshFor { return }
        queryTask?.cancel()
        querying = true
        queryError = nil
        queryTask = Task {
            let outcome = await Task.detached { () -> Result<JiraSearch, JiraError> in
                do { return .success(try await client.search(jql: jql, max: JiraTickets.pageSize, fields: JiraLogic.listFields)) } catch {
                    return .failure(JiraError.from(error))
                }
            }.value
            guard !Task.isCancelled else { return }
            querying = false
            switch outcome {
            case .success(let search):
                results[jql] = QueryResult(tickets: search.tickets, fetched: Date())
                if results.count > Self.keptQueries { results = results.sorted { $0.value.fetched > $1.value.fetched }.prefix(Self.keptQueries).reduce(into: [:]) { $0[$1.key] = $1.value } }
                learnPeople(search.tickets)
            case .failure(let error): queryError = error
            }
        }
    }

    private func persistState() {
        guard persisting else { return }
        defaults.set(JiraPageState.encode(JiraPageState(tab: tab, filter: filter)), forKey: JiraSavedViews.pageStateKey)
    }

    func saveView(named name: String) {
        savedViews = JiraSavedViews.saving(JiraSavedView(name: name, tab: tab, filter: filter), in: savedViews)
        defaults.set(JiraSavedViews.encode(savedViews), forKey: JiraSavedViews.key)
    }

    func deleteView(_ view: JiraSavedView) {
        savedViews = JiraSavedViews.removing(view.name, from: savedViews)
        defaults.set(JiraSavedViews.encode(savedViews), forKey: JiraSavedViews.key)
    }

    func apply(_ view: JiraSavedView) {
        tab = view.tab
        filter = view.filter
    }

    var currentView: JiraSavedView? { JiraSavedViews.current(tab, filter, in: savedViews) }

    var suggestedViewName: String { JiraQuery.summary(tab, filter, people: people) }

    /// Remembers who people are by account id, as the filters hold only the id.
    func learnPeople(_ tickets: some Sequence<JiraTicket>) {
        let found = JiraTickets.people(Array(tickets))
        guard !found.isEmpty, found.contains(where: { people[$0.id] != $0.name }) else { return }
        remember(found)
    }

    func remember(_ persons: [JiraPerson]) {
        persons.forEach { people[$0.id] = $0.name }
        defaults.set(people, forKey: Self.peopleKey)
    }

    /// People matching what is typed, for the filter, or those a ticket can be assigned to.
    func findPeople(_ query: String, assignableTo key: String? = nil) async -> [JiraPerson] {
        guard let client = jira.client() else { return [] }
        let result = await Task.detached { () -> Result<[JiraPerson], JiraError> in
            do { return .success(try await client.people(matching: query, assignableTo: key)) } catch { return .failure(JiraError.from(error)) }
        }.value
        switch result {
        case .success(let found): return found
        case .failure(let error):
            showNotice(error.message)
            return []
        }
    }

    // MARK: Changing a ticket

    func loadTransitions(_ key: String, force: Bool = false) {
        if !force, let at = transitionFetched[key], Date().timeIntervalSince(at) < Self.transitionsFreshFor { return }
        guard let client = jira.client() else {
            transitionErrors[key] = .notConfigured
            return
        }
        transitionFetched[key] = Date()
        transitionErrors[key] = nil
        loadingTransitions.insert(key)
        Task {
            let result = await Task.detached { () -> Result<[JiraTransition], JiraError> in
                do { return .success(try await client.transitions(of: key)) } catch { return .failure(JiraError.from(error)) }
            }.value
            loadingTransitions.remove(key)
            switch result {
            case .success(let list): transitions[key] = list
            case .failure(let error):
                transitionFetched[key] = nil
                transitionErrors[key] = error
            }
        }
    }

    /// Moves the ticket now, as far as the page shows, and puts it back with Jira's answer if Jira refuses.
    func move(_ key: String, with transition: JiraTransition, values: [String: [String]] = [:], offersUndo: Bool = true) {
        guard let client = jira.client() else { return showNotice(JiraError.notConfigured.message) }
        let before = snapshot(key), from = before.ticket?.status ?? before.issue?.status
        edit(key, ticket: { JiraWrite.moved($0, to: transition) }, issue: { var issue = $0; issue.status = transition.status; return issue })
        statusPicker = nil
        Task {
            let failure = await Task.detached { () -> JiraError? in
                do { try await client.move(key, with: transition, values: values); return nil } catch { return JiraError.from(error) }
            }.value
            if let failure {
                restore(key, before)
                return showNotice(failure.message)
            }
            transitions[key] = nil
            transitionFetched[key] = nil
            loadDetail(key, force: true)
            if offersUndo, let from { offerUndo(key: key, from: from, to: transition.status, client: client) }
            save()
            await refresh()
        }
    }

    private func offerUndo(key: String, from: String, to status: String, client: JiraClient) {
        undo = Undo(key: key, from: from, text: "\(key) moved to \(status)", transition: nil)
        undoTimer.schedule(after: Self.undoSeconds) { [weak self] in MainActor.assumeIsolated { self?.undo = nil } }
        Task {
            let list = await Task.detached { try? await client.transitions(of: key) }.value
            guard let list, undo?.key == key else { return }
            transitions[key] = list
            transitionFetched[key] = Date()
            undo?.transition = JiraWrite.undo(to: from, among: list)
        }
    }

    func undoMove() {
        guard let undo, let back = undo.transition else { return }
        self.undo = nil
        move(undo.key, with: back, offersUndo: false)
    }

    func assign(_ key: String, to person: JiraPerson?) {
        guard let client = jira.client() else { return showNotice(JiraError.notConfigured.message) }
        let before = snapshot(key)
        if let person { remember([person]) }
        edit(key, ticket: { JiraWrite.assigned($0, to: person) }, issue: { var issue = $0; issue.assignee = person?.name; return issue })
        assignPicker = nil
        Task {
            let failure = await Task.detached { () -> JiraError? in
                do { try await client.assign(key, to: person); return nil } catch { return JiraError.from(error) }
            }.value
            if let failure {
                restore(key, before)
                return showNotice(failure.message)
            }
            loadDetail(key, force: true)
            save()
            await refresh()
        }
    }

    func assignToMe(_ key: String) {
        Task {
            guard let me = await currentUser() else { return }
            assign(key, to: me)
        }
    }

    private func currentUser() async -> JiraPerson? {
        if let myself { return myself }
        guard let client = jira.client() else { return nil }
        let result = await Task.detached { () -> Result<JiraPerson, JiraError> in
            do { return .success(try await client.me()) } catch { return .failure(JiraError.from(error)) }
        }.value
        switch result {
        case .success(let person) where !person.id.isEmpty:
            myself = person
            return person
        case .success: showNotice("Jira did not say who you are")
        case .failure(let error): showNotice(error.message)
        }
        return nil
    }

    /// Posts the comment as the user, on their click; true when Jira took it and it shows under the ticket.
    func postComment(on key: String, text: String) async -> Bool {
        guard let client = jira.client() else {
            showNotice(JiraError.notConfigured.message)
            return false
        }
        let result = await Task.detached { () -> Result<JiraIssue.Comment, JiraError> in
            do { return .success(try await client.comment(on: key, text: text)) } catch { return .failure(JiraError.from(error)) }
        }.value
        switch result {
        case .success(let comment):
            if case .loaded(var issue)? = details[key] {
                issue.comments.append(comment)
                issue.commentTotal += 1
                details[key] = .loaded(issue)
            }
            drafts[key] = nil
            return true
        case .failure(let error):
            showNotice(error.message)
            return false
        }
    }

    private struct Snapshot {
        var ticket: JiraTicket?
        var issue: JiraIssue?
    }

    private func snapshot(_ key: String) -> Snapshot {
        var issue: JiraIssue?
        if case .loaded(let loaded)? = details[key] { issue = loaded }
        return Snapshot(ticket: ticket(key), issue: issue)
    }

    private func restore(_ key: String, _ snapshot: Snapshot) {
        edit(key, ticket: { snapshot.ticket ?? $0 }, issue: { snapshot.issue ?? $0 })
    }

    /// Applies a change to the ticket wherever the page holds it: the lists, the query results and the open issue.
    private func edit(_ key: String, ticket change: (JiraTicket) -> JiraTicket, issue changeIssue: (JiraIssue) -> JiraIssue) {
        for tab in Array(lists.keys) { lists[tab] = lists[tab]?.map { $0.key == key ? change($0) : $0 } }
        for jql in Array(results.keys) { results[jql]?.tickets = results[jql]?.tickets.map { $0.key == key ? change($0) : $0 } ?? [] }
        if case .loaded(let issue)? = details[key] { details[key] = .loaded(changeIssue(issue)) }
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
        persisting = false
        self.lists = lists
        self.pullRequests = pullRequests
        self.error = error
        self.fetched = fetched
        tab = .assigned
        filter = JiraFilter()
    }

    func showSample(issue: JiraIssue, transitions: [JiraTransition] = [], undo: Undo? = nil) {
        details[issue.key] = .loaded(issue)
        detailFetched[issue.key] = Date()
        self.transitions[issue.key] = transitions
        transitionFetched[issue.key] = Date()
        self.undo = undo
        selected = issue.key
    }

    func showSample(statusPicker key: String?) { statusPicker = key }
    #endif
}
