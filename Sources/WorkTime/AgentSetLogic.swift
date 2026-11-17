import Foundation

/// A pull request linked to an agent that works on several at once.
struct LinkedPR: Codable, Equatable, Hashable, Sendable {
    var url: String
    var repo: String
    var number: Int
    var title: String?
    /// The repository's checkout on this Mac, when WorkTime found one.
    var checkout: String?

    init(url: String, repo: String, number: Int, title: String? = nil, checkout: String? = nil) {
        self.url = url
        self.repo = repo
        self.number = number
        self.title = title
        self.checkout = checkout
    }

    init(target: GitHubLink.Target, title: String? = nil, checkout: String? = nil) {
        self.init(url: target.url, repo: target.repo, number: target.number, title: title, checkout: checkout)
    }

    init?(url: String) {
        guard let target = GitHubLink.pullRequest(at: url) else { return nil }
        self.init(target: target)
    }

    var target: GitHubLink.Target { GitHubLink.Target(repo: repo, number: number) }

    /// `owner/repo#12`.
    var label: String { "\(repo)#\(number)" }

    /// `repo#12`, without the owner.
    var shortLabel: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)" }
}

/// An agent for several pull requests: a topic agent whose links are pull requests. A pull request is in at most one set, and
/// opening it from a list opens its set's agent.
enum PullRequestSets {
    static let limit = 10
    static let nameLimit = 60

    /// The pull requests the urls name, once each and in order, or the first that is not one.
    static func linked(_ urls: [String]) -> Result<[LinkedPR], AgentSetError> {
        var found: [LinkedPR] = []
        for url in urls {
            guard let pr = LinkedPR(url: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .failure(.notPullRequest(url)) }
            if !found.contains(where: { $0.url == pr.url }) { found.append(pr) }
        }
        guard found.count <= limit else { return .failure(.tooMany(found.count)) }
        return .success(found)
    }

    /// `existing` with the new ones added: known ones keep their place and take on a title or checkout they were missing.
    static func adding(_ new: [LinkedPR], to existing: [LinkedPR]) -> [LinkedPR] {
        var result = existing
        for pr in new {
            if let index = result.firstIndex(where: { $0.url == pr.url }) {
                result[index].title = result[index].title ?? pr.title
                result[index].checkout = result[index].checkout ?? pr.checkout
            } else {
                result.append(pr)
            }
        }
        return result
    }

    static func removing(_ url: String, from existing: [LinkedPR]) -> [LinkedPR] { existing.filter { $0.url != url } }

    /// The set agent that holds the pull request, one that is not archived first.
    static func set(containing url: String, in topics: [TopicAgent]) -> TopicAgent? {
        let holding = topics.filter { $0.linked.contains { $0.url == url } }
        return holding.first { !$0.archived } ?? holding.first
    }

    /// The set agent already working on all of these pull requests.
    static func set(coveringAll urls: [String], in topics: [TopicAgent]) -> TopicAgent? {
        topics.first { topic in !topic.archived && !topic.linked.isEmpty && urls.allSatisfy { url in topic.linked.contains { $0.url == url } } }
    }

    /// Where a pull request's prompt or opening goes: its set agent's key when it is in a set, else its own url.
    static func route(_ url: String, in topics: [TopicAgent]) -> String {
        set(containing: url, in: topics).map(\.key) ?? url
    }

    /// The topics with the pull requests taken out of every set but `key`: a pull request is in one set only.
    static func assigning(_ urls: [String], to key: String, in topics: [TopicAgent]) -> [TopicAgent] {
        topics.map { topic in
            guard topic.key != key, topic.linked.contains(where: { urls.contains($0.url) }) else { return topic }
            var topic = topic
            topic.pullRequests = topic.linked.filter { !urls.contains($0.url) }
            return topic
        }
    }

    /// The set's name: the first references, then how many more.
    static func name(_ prs: [LinkedPR]) -> String {
        let shown = prs.prefix(2).map(\.shortLabel).joined(separator: ", ")
        let rest = prs.count - 2
        return ActivityLogic.truncate("Review: " + shown + (rest > 0 ? " +\(rest)" : ""), to: nameLimit)
    }

    /// The folder the set works in: the checkout all its pull requests share, else its own.
    static func workingFolder(_ prs: [LinkedPR], own: String) -> String {
        let checkouts = Set(prs.compactMap(\.checkout))
        return checkouts.count == 1 && prs.allSatisfy({ $0.checkout != nil }) ? checkouts.first! : own
    }

    /// Whether the folder was picked for these pull requests (a repository's checkout), not the set's own.
    static func shares(folder: String, _ prs: [LinkedPR]) -> Bool { prs.contains { $0.checkout == folder } }

    static func lines(_ prs: [LinkedPR]) -> String {
        prs.map { pr in
            "- \(pr.url)" + (pr.title.map { " \u{2014} \($0)" } ?? "") + (pr.checkout.map { " (checkout: \($0))" } ?? " (no checkout found)")
        }.joined(separator: "\n")
    }

    /// The prompt waiting in a new set agent's composer.
    static func prompt(_ prs: [LinkedPR]) -> String {
        "Review these \(prs.count) pull requests as one change. For each, read it with github_pr and the diff, then draft a verdict "
            + "(approve, request changes or needs the author's input) with the blocking problems and the small ones. Then check that they are "
            + "consistent with each other: the contracts, migrations, permissions and tests that must agree across them. "
            + "You only draft: do not post, approve or comment.\n\n" + lines(prs)
    }

    static func systemPrompt(_ topic: TopicAgent) -> String {
        let prs = topic.linked
        return """
            You are working in WorkTime on \(prs.count) pull request\(prs.count == 1 ? "" : "s") that belong together, as \u{201C}\(topic.name)\u{201D}. \
            Treat them as one change: look for what must agree across them, and say which pull request each finding belongs to.
            The pull requests (the list can change while you work; this is the current one):
            \(lines(prs))
            Read each with the worktime github_pr tool and `gh pr diff`; open the files in the checkout listed for it when the diff is not enough, \
            and the working folder is \(topic.folder). Draft one verdict per pull request, then the cross-pull-request findings, as text for the user.
            You never post, approve, merge or comment on GitHub or anywhere else, and must never claim you did. The user posts the reviews themselves.
            """
    }

    /// The pull requests added to a topic that has a ticket or thread of its own.
    static func linkedSection(_ prs: [LinkedPR]) -> String {
        "Pull requests linked to this topic (read each with github_pr and `gh pr diff`; you only draft, never post, approve or comment):\n" + lines(prs)
    }

    /// The urls of every pull request a text mentions when there are several, else none: the case for a set.
    static func urls(in text: String) -> [String]? {
        let found = GitHubLink.mentions(in: text).map(\.url)
        return found.count > 1 ? Array(found.prefix(limit)) : nil
    }

    static func summary(_ prs: [LinkedPR]) -> String { prs.map(\.label).joined(separator: ", ") }
}

enum AgentSetError: Error, Equatable {
    case notPullRequest(String)
    case tooMany(Int)
    case needTwo

    var message: String {
        switch self {
        case .notPullRequest(let text): return "\u{201C}\(text)\u{201D} is not a GitHub pull request url."
        case .tooMany(let count): return "\(count) pull requests is too many for one agent; the limit is \(PullRequestSets.limit)."
        case .needTwo: return "A set needs at least two pull requests; use pr_url for one."
        }
    }
}
