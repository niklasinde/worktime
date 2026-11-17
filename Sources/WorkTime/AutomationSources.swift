import Combine
import Foundation

/// Hands the automations the events they wait for. The Slack mentions and direct messages, and the pull requests, come from the
/// lists the app already follows, each handed over once its source has fetched, so an empty list is never mistaken for everything
/// being new. The rest (channel messages, keywords, thread replies, Jira, a repository's pull requests) are searched on a timer, and
/// only for the automations that are on; with none, nothing is fetched. The Slack ones also arrive within seconds over Slack's
/// Socket Mode when an app-level token is set up; the search stays as the safety net for what that missed.
@MainActor
final class AutomationSources {
    static let shared = AutomationSources()
    static let pollInterval: TimeInterval = 300

    private struct Polled: Equatable {
        let id: String
        let trigger: AutomationTrigger
    }

    private var subscriptions: Set<AnyCancellable> = []
    var socketSubscriptions: Set<AnyCancellable> = []
    private var loop: Task<Void, Never>?
    private var polling = false
    let socketNames = SlackSocketNames()

    func start() {
        subscriptions = []
        let slack = SlackModel.shared
        slack.$messages.combineLatest(slack.$fetched)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages, fetched in
                guard fetched != nil else { return }
                self?.hand(kind: .slackMessage, events: Self.slackEvents(messages, workspace: slack.identity?.url))
            }
            .store(in: &subscriptions)
        let github = GitHubModel.shared
        github.$prs.combineLatest(github.$fetched)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prs, fetched in
                guard fetched != nil else { return }
                for (kind, events) in Automations.githubEvents(prs) { self?.hand(kind: kind, events: events) }
            }
            .store(in: &subscriptions)
        RoutineStore.shared.$routines
            .map { $0.compactMap { routine in routine.enabled ? routine.trigger.flatMap { $0.kind.polled ? Polled(id: routine.id, trigger: $0) : nil } : nil } }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.poll() } }
            .store(in: &subscriptions)
        socketSubscriptions = []
        startSocket()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval) * 1_000_000_000)
                self?.updateSocket()
                await self?.poll()
            }
        }
    }

    private func hand(kind: AutomationTrigger.Kind, events: [AutomationEvent], only routine: String? = nil) {
        RoutineStore.shared.ingest(kind: kind, events: events, only: routine)
    }

    static func slackEvents(_ messages: [SlackMessage], workspace: String?) -> [AutomationEvent] {
        messages.filter { $0.handled == nil }.map { Automations.slackEvent($0, link: SlackLogic.webLink($0, workspace: workspace)) }
    }

    // MARK: Polling

    /// Searches for the automations that need it. A search that fails hands nothing over, so a failure is never taken for an empty answer.
    func poll() async {
        let store = RoutineStore.shared
        guard !polling, store.automationsEnabled() else { return }
        let wanted = store.routines.filter { $0.enabled && $0.trigger?.kind.polled == true }
        guard !wanted.isEmpty else { return }
        polling = true
        defer { polling = false }
        func routines(_ source: AutomationTrigger.Source) -> [Routine] { wanted.filter { $0.trigger?.kind.source == source } }
        await pollSlack(routines(.slack))
        await pollJira(routines(.jira))
        await pollGitHub(routines(.github))
    }

    private func pollSlack(_ routines: [Routine]) async {
        guard !routines.isEmpty, SlackModel.shared.configured, let access = MCPServer.storedSlack() else { return }
        let known = SlackModel.shared.identity
        var cache: [String: [SlackMessage]] = [:]
        for routine in routines {
            guard let trigger = routine.trigger else { continue }
            do {
                let events = try await access.run { client -> [AutomationEvent] in
                    let me: SlackIdentity
                    if let known { me = known } else { me = try await client.identity() }
                    func search(_ query: String) async throws -> [SlackMessage] {
                        if let found = cache[query] { return found }
                        let found = try await client.search(query, count: Automations.slackCount, teamID: me.teamID)
                        cache[query] = found
                        return found
                    }
                    var messages: [SlackMessage] = []
                    for query in Automations.slackQueries(trigger, now: Date()) { messages += try await search(query) }
                    guard trigger.kind == .slackReply else {
                        return Automations.slackSearchEvents(messages, kind: trigger.kind, me: me, workspace: me.url)
                    }
                    var events: [AutomationEvent] = []
                    for (root, link) in Automations.slackThreads(messages) {
                        let thread = try await client.thread(link)
                        let names = await client.names(thread.messages.compactMap(\.user))
                        events += Automations.slackReplyEvents(thread.messages, root: root, link: link, names: names, me: me, workspace: me.url, now: Date())
                    }
                    return events
                }
                hand(kind: trigger.kind, events: events, only: routine.id)
            } catch { continue }
        }
    }

    private func pollJira(_ routines: [Routine]) async {
        guard !routines.isEmpty, JiraModel.shared.ready, let access = MCPServer.storedJira() else { return }
        var me: String?
        for routine in routines {
            guard let trigger = routine.trigger else { continue }
            do {
                if me == nil { me = try JiraLogic.parseMyself(await access.client.send(path: JiraLogic.myselfPath)).id }
                guard let account = me else { continue }
                let data = try await access.client.searchData(body: Automations.jiraBody(jql: Automations.jiraQuery(trigger), kind: trigger.kind))
                hand(kind: trigger.kind, events: try Automations.jiraEvents(data, kind: trigger.kind, site: access.site, me: account, now: Date()), only: routine.id)
            } catch { continue }
        }
    }

    private func pollGitHub(_ routines: [Routine]) async {
        let model = GitHubModel.shared
        guard !routines.isEmpty, model.enabled, let cli = GitHubLogic.findCLI() else { return }
        let known = GitHubLogic.repos(in: model.prs.values.flatMap { $0 })
        var cache: [String: [GitHubPR]] = [:]
        for routine in routines {
            guard let trigger = routine.trigger else { continue }
            let repos = Automations.repositories(trigger.place, known: known)
            guard !repos.isEmpty else { continue }
            var found: [GitHubPR] = []
            var failed = false
            for repo in repos {
                if cache[repo] == nil { cache[repo] = await Task.detached { Self.search(cli: cli, repo: repo) }.value }
                guard let prs = cache[repo] else { failed = true; break }
                found += prs
            }
            guard !failed else { continue }
            hand(kind: trigger.kind, events: Automations.repositoryEvents(found)[trigger.kind] ?? [], only: routine.id)
        }
    }

    private nonisolated static func search(cli: URL, repo: String) -> [GitHubPR]? {
        guard let output = GitHubClient.run(cli, GitHubLogic.arguments(for: Automations.repositorySearch(repo))), output.status == 0 else { return nil }
        return try? GitHubLogic.parsePage(output.stdout).prs
    }
}
