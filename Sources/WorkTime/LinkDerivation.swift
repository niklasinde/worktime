import Foundation

/// What the app knows that links are derived from.
struct LinkContext: Sendable {
    var projects: Set<String> = []
    /// Pull requests' titles by address, for agents that name a ticket only through their pull request.
    var titles: [String: String] = [:]
    /// The branch each agent's folder is on, by agent key, as a branch entity's id.
    var branches: [String: String] = [:]
}

/// The links the data the app already has implies: an agent's ticket, pull requests, branch and Slack thread, and the ticket and branch
/// of every pull request, which need no agent at all.
enum LinkDerivation {
    static func pairs(for state: AgentState, context: LinkContext) -> [LinkPair] {
        let agent = LinkEntity.agent(state.key)
        var others: [LinkEntity] = []
        if let ticket = TicketGrouping.subject(of: state, projects: context.projects, titles: context.titles)?.ticket { others.append(.jira(ticket)) }
        others += ([state.prURL, state.sessionPR] + (state.pullRequests ?? []).map(Optional.some)).compactMap { $0.flatMap(LinkTargets.pullRequest) }
        if let slack = state.slackURL.flatMap(LinkTargets.slack) { others.append(slack) }
        var pairs: [LinkPair] = []
        if let branch = context.branches[state.key] {
            others.append(.branch(branch))
            let named = branchTickets(branch, projects: context.projects)
            pairs += named.map { LinkPair(.branch(branch), $0) }
            others += named
        }
        return others.map { LinkPair(agent, $0) } + pairs
    }

    /// A pull request's tickets, named in its title or its branch, and its branch: no agent needed.
    static func pairs(pullRequest url: String, title: String?, head: String?, projects: Set<String>) -> [LinkPair] {
        guard let target = GitHubLink.pullRequest(at: url) else { return [] }
        let pullRequest = LinkEntity.pullRequest(target)
        var pairs = tickets(in: title ?? "", projects: projects).map { LinkPair(pullRequest, $0) }
        guard let head, let branch = LinkTargets.branch(repo: target.repo, name: head) else { return pairs }
        pairs.append(LinkPair(pullRequest, branch))
        pairs += branchTickets(branch.id, projects: projects).map { LinkPair(pullRequest, $0) }
        return pairs + branchTickets(branch.id, projects: projects).map { LinkPair(branch, $0) }
    }

    static func pairs(for pr: GitHubPR, projects: Set<String>) -> [LinkPair] {
        pairs(pullRequest: pr.url, title: pr.title, head: pr.head, projects: projects)
    }

    static func pairs(for event: GitHubEvent, projects: Set<String>) -> [LinkPair] {
        event.pullRequestURL.map { pairs(pullRequest: $0, title: event.title, head: event.headRef, projects: projects) } ?? []
    }

    static func pairs(states: [AgentState], pullRequests: [GitHubPR], context: LinkContext) -> [LinkPair] {
        let found = states.flatMap { pairs(for: $0, context: context) } + pullRequests.flatMap { pairs(for: $0, projects: context.projects) }
        var seen = Set<LinkPair>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The Jira projects tickets may belong to: the configured ones and the prefixes of the keys agents carry.
    static func projects(configured: [String], states: [AgentState]) -> Set<String> {
        SessionProjects.set(configured: configured, pinned: states.compactMap(\.jiraKey).map(SessionRef.jira))
    }

    static func tickets(in text: String, projects: Set<String>) -> [LinkEntity] {
        projects.isEmpty ? [] : SessionLinks.references(in: text, projects: projects).compactMap(\.key).map(LinkEntity.jira)
    }

    private static func branchTickets(_ branch: String, projects: Set<String>) -> [LinkEntity] {
        tickets(in: String(branch.drop { $0 != ":" }.dropFirst()), projects: projects)
    }
}

/// The branch a folder is on, read from the repository's HEAD without running git.
enum LinkBranches {
    static let depth = 4

    /// `repo:branch` for the checkout `folder` is in or under; nil outside a repository or on a detached HEAD.
    static func current(folder: String?, fileManager: FileManager = .default) -> String? {
        guard var directory = folder.map({ URL(fileURLWithPath: $0) }) else { return nil }
        for _ in 0..<depth {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                return branch(git: git, isDirectory: isDirectory.boolValue, checkout: directory)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func branch(git: URL, isDirectory: Bool, checkout: URL) -> String? {
        var gitDirectory = git
        var repo = checkout.lastPathComponent
        if !isDirectory {
            guard let text = try? String(contentsOf: git, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
            gitDirectory = URL(fileURLWithPath: String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: checkout).standardizedFileURL
            if let range = gitDirectory.path.range(of: "/.git/worktrees/") {
                repo = URL(fileURLWithPath: String(gitDirectory.path[..<range.lowerBound])).lastPathComponent
            }
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8),
              head.hasPrefix("ref: refs/heads/") else { return nil }
        return LinkTargets.branch(repo: repo, name: String(head.dropFirst(16)))?.id
    }
}
