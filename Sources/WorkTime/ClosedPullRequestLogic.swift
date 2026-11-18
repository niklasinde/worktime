import Foundation

/// What a merged or closed pull request leaves behind that nobody needs to answer any more: drafted reviews, questions and
/// review notifications about it, and the reminders an agent raised for it.
enum ClosedPullRequests {
    struct Resolution: Equatable {
        var drafts: [ReviewDraft] = []
        var notices: [String] = []
        var reminders: [String] = []

        var isEmpty: Bool { drafts.isEmpty && notices.isEmpty && reminders.isEmpty }
    }

    static func states(of prs: [GitHubPR]) -> [String: GitHubPR.State] {
        Dictionary(prs.map { ($0.url, $0.state) }, uniquingKeysWith: { _, new in new })
    }

    /// The pull requests the notices and reminders are about, to look up when their state is not known.
    static func urls(notices: [AgentNotice], reminders: [Reminder]) -> [String] {
        let found = notices.flatMap(addresses) + reminders.compactMap(address)
        return found.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// What is obsolete when the pull requests in `states` are not open; a pull request without a state is taken as open.
    static func resolution(notices: [AgentNotice], reminders: [Reminder], states: [String: GitHubPR.State]) -> Resolution {
        func closed(_ url: String) -> Bool { states[url].map { $0 != .open } ?? false }
        var result = Resolution()
        for notice in notices {
            if let reviews = notice.reviews {
                result.drafts += reviews.filter { closed(url(of: $0)) }
            } else {
                let urls = addresses(notice)
                if !urls.isEmpty, urls.allSatisfy(closed) { result.notices.append(notice.id) }
            }
        }
        result.reminders = reminders.filter { address($0).map(closed) ?? false }.map(\.id)
        return result
    }

    private static func url(of draft: ReviewDraft) -> String { draft.target?.url ?? draft.pr }

    private static func addresses(_ notice: AgentNotice) -> [String] {
        if let reviews = notice.reviews { return reviews.map(url(of:)) }
        guard notice.ask != nil || NoticeLogic.isReview(notice) || Decisions.needsAnswer(notice) else { return [] }
        let asked = notice.ask?.pullRequests ?? notice.ask?.pullRequest.map { [$0] } ?? []
        return (asked.isEmpty ? [notice.link].compactMap { $0 } : asked).compactMap { GitHubLink.pullRequest(at: $0)?.url }
    }

    private static func address(_ reminder: Reminder) -> String? {
        guard reminder.isOpen, reminder.addedBy != nil, let source = reminder.source else { return nil }
        switch source.kind {
        case .githubPR:
            let parts = source.reference.split(separator: "#")
            return parts.count == 2 ? GitHubLink.pullRequest(at: "https://github.com/\(parts[0])/pull/\(parts[1])")?.url : nil
        case .url: return GitHubLink.pullRequest(at: source.reference)?.url
        default: return nil
        }
    }
}
