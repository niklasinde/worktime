import Foundation

/// The pull request events: from the lists the app already follows, and from a search of a repository.
extension Automations {
    /// What the cached lists make, per kind of event. A kind is there, with no events when none, once its list has loaded, so a first look can
    /// mark what exists as seen and a list that failed to load is never mistaken for an empty one.
    static func githubEvents(_ lists: [GitHubKind: [GitHubPR]]) -> [AutomationTrigger.Kind: [AutomationEvent]] {
        func open(_ prs: [GitHubPR]) -> [GitHubPR] { prs.filter { $0.state == .open } }
        var events: [AutomationTrigger.Kind: [AutomationEvent]] = [:]
        if let requested = lists[.reviewRequested] {
            events[.reviewRequested] = open(requested).filter { !$0.isDraft }.map { pullRequestEvent($0) }
        }
        if let mentioned = lists[.mentioned] {
            events[.prMentioned] = open(mentioned).filter { $0.author != $0.activity?.me }.map { pullRequestEvent($0, kind: .prMentioned) }
        }
        if let mine = lists[.created] {
            events[.ciFailed] = open(mine).filter { $0.checks == .failed }.map { pullRequestEvent($0, kind: .ciFailed, suffix: push($0)) }
            events[.prApproved] = open(mine).filter { $0.review == .approved }.map { pullRequestEvent($0, kind: .prApproved) }
            events[.prMerged] = mine.filter { $0.state == .merged }.map { pullRequestEvent($0, kind: .prMerged) }
            events[.prFeedback] = open(mine).flatMap(feedbackEvents)
        }
        return events
    }

    /// The events of one searched repository: each pull request once as opened, and once more for every update.
    static func repositoryEvents(_ prs: [GitHubPR]) -> [AutomationTrigger.Kind: [AutomationEvent]] {
        let open = prs.filter { $0.state == .open && !$0.isDraft }
        return [
            .prOpened: open.map { pullRequestEvent($0, kind: .prOpened) },
            .prUpdated: open.map { pullRequestEvent($0, kind: .prUpdated, suffix: seconds($0.updated)) },
        ]
    }

    /// The reviews and the last comment by someone else on my pull request, each an event of its own.
    static func feedbackEvents(_ pr: GitHubPR) -> [AutomationEvent] {
        guard let activity = pr.activity else { return [] }
        func event(_ actor: GitHubActivity.Actor, _ state: String, _ date: Date, _ kind: String) -> AutomationEvent? {
            guard actor.login != activity.me, !actor.isBot else { return nil }
            return pullRequestEvent(pr, kind: .prFeedback, suffix: "\(kind):\(actor.login):\(seconds(date))",
                                    extra: ["reviewer": actor.login, "review_state": state], date: date)
        }
        let reviews = activity.reviews.compactMap { event($0.actor, $0.state.lowercased().replacingOccurrences(of: "_", with: " "), $0.date, "review") }
        return reviews + [activity.lastComment.flatMap { event($0.actor, "comment", $0.date, "comment") }].compactMap { $0 }
    }

    /// The search of one repository for the pull requests of other people, newest update first.
    static func repositorySearch(_ repo: String) -> GitHubLogic.Search {
        GitHubLogic.Search(kind: .reviewed, terms: "repo:\(repo) is:pr is:open -author:@me archived:false sort:updated-desc", limit: 20, discussion: false)
    }

    /// The repositories a trigger names: `owner/name` as typed, a bare name matched to a repository the app knows.
    static func repositories(_ place: String, known: [String]) -> [String] {
        words(place).compactMap { word in
            if word.contains("/") { return word }
            return known.first { GitHubLogic.repoName($0).name.caseInsensitiveCompare(word) == .orderedSame }
        }
    }

    private static func push(_ pr: GitHubPR) -> String { seconds(pr.activity?.lastCommit ?? pr.updated) }

    private static func seconds(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }
}
