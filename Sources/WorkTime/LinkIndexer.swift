import Foundation

/// Keeps the link table up to date from what the app knows, outside any view: a few seconds after the agents or the pull request lists
/// change, and at once for a webhook event that names a branch.
@MainActor
final class LinkIndexer {
    static let shared = LinkIndexer()
    static let debounce: TimeInterval = 3

    private var scheduled = false

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in self?.run() }
    }

    func ingest(event: GitHubEvent) {
        let pairs = LinkDerivation.pairs(for: event, projects: projects(states: []))
        if !pairs.isEmpty { LinkStore.shared.ingest(pairs) }
    }

    private func projects(states: [AgentState]) -> Set<String> {
        LinkDerivation.projects(configured: WorkspaceStore.shared.workspaces.flatMap(\.jiraProjects), states: states)
    }

    private func run() {
        scheduled = false
        let states = AgentStateWriter.shared.states()
        let github = GitHubModel.shared
        let pullRequests = GitHubLogic.unique(github.prs) + github.watchedPRs
        let base = LinkContext(projects: projects(states: states), titles: Dictionary(pullRequests.map { ($0.url, $0.title) }) { first, _ in first })
        Task.detached(priority: .utility) {
            var context = base
            for state in states {
                if let branch = LinkBranches.current(folder: state.folder) { context.branches[state.key] = branch }
            }
            let pairs = LinkDerivation.pairs(states: states, pullRequests: pullRequests, context: context)
            await LinkStore.shared.ingest(pairs)
        }
    }
}
