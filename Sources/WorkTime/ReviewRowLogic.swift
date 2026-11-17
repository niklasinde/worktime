import Foundation

/// What a review row knows about its pull request besides the draft; empty where the app has not seen the pull request.
struct ReviewPRInfo: Equatable, Sendable {
    var title = ""
    var author: String?
    var additions = 0
    var deletions = 0
    var checks = GitHubPR.Checks.none

    init(title: String = "", author: String? = nil, additions: Int = 0, deletions: Int = 0, checks: GitHubPR.Checks = .none) {
        self.title = title
        self.author = author
        self.additions = additions
        self.deletions = deletions
        self.checks = checks
    }

    init(_ pr: GitHubPR) { self.init(title: pr.title, author: pr.author, additions: pr.additions, deletions: pr.deletions, checks: pr.checks) }

    var size: String? { additions + deletions > 0 ? "+\(additions)/\u{2212}\(deletions)" : nil }

    var checksText: String? {
        switch checks {
        case .passed: return "checks passed"
        case .failed: return "checks failing"
        case .running: return "checks running"
        case .none: return nil
        }
    }
}

/// How a drafted review is shown as a row: what it recommends, why, and the one click that posts it as drafted.
enum ReviewRows {
    enum Tone: Equatable { case positive, negative, neutral }

    static let reasonLimit = 220
    static let commentLimit = 100
    private static let blockingWords = ["must ", "blocker", "blocking", "before merge", "will fail", "fails", "breaks", "crash", "wrong"]

    static func tone(_ verdict: ReviewDraft.Verdict) -> Tone {
        switch verdict {
        case .approve: return .positive
        case .requestChanges: return .negative
        case .comment: return .neutral
        }
    }

    // MARK: Text

    /// The pull request's name in a row: its address and, when known, its title.
    static func heading(_ draft: ReviewDraft, info: ReviewPRInfo) -> String {
        info.title.isEmpty ? draft.reference : draft.reference + " " + info.title
    }

    /// Who wrote it, how big it is and where its checks are, for the line under the heading.
    static func meta(_ info: ReviewPRInfo) -> String {
        [info.author, info.size, info.checksText].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// The first two sentences of the review's summary, on one line.
    static func reason(_ draft: ReviewDraft, limit: Int = reasonLimit) -> String {
        let text = ReviewDraft.untagged(draft.summary).split(whereSeparator: \.isNewline).joined(separator: " ")
        return clipped(sentences(text, count: 2), limit)
    }

    /// The first `count` sentences of a text: a sentence ends at a full stop, question mark or exclamation mark before a space.
    static func sentences(_ text: String, count: Int) -> String {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var found = 0
        var end = characters.count
        for index in characters.indices where ".!?".contains(characters[index]) {
            let next = index + 1
            if next == characters.count || characters[next] == " " {
                found += 1
                if found == count { end = next; break }
            }
        }
        return String(characters[..<end]).trimmingCharacters(in: .whitespaces)
    }

    static func blocking(_ draft: ReviewDraft) -> [ReviewDraft.Comment] {
        draft.comments.filter { comment in blockingWords.contains { comment.body.lowercased().contains($0) } }
    }

    /// "2 blocking \u{00B7} 3 comments on lines", nil when there are no comments.
    static func counts(_ draft: ReviewDraft) -> String? {
        let total = draft.comments.count
        guard total > 0 else { return nil }
        var parts: [String] = []
        let blocked = blocking(draft).count
        if blocked > 0 { parts.append("\(blocked) blocking") }
        parts.append("\(total) comment\(total == 1 ? "" : "s") on lines")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The comment to show first: the first blocking one when the review asks for changes, else the first.
    static func firstComment(_ draft: ReviewDraft) -> String? {
        let pick = (draft.verdict == .requestChanges ? blocking(draft).first : nil) ?? draft.comments.first
        return pick.map { "\($0.label) \u{2014} " + clipped(ReviewDraft.untagged($0.body).split(whereSeparator: \.isNewline).joined(separator: " "), commentLimit) }
    }

    // MARK: The click

    /// What the draft's own verdict posts: an approval, a request for changes, or a plain comment.
    static func primary(_ draft: ReviewDraft) -> ReviewAction {
        switch draft.verdict {
        case .approve: return .approve
        case .requestChanges: return .requestChanges
        case .comment: return .postComments
        }
    }

    /// The main button, named for what it does: "Request changes \u{00B7} 3 comments", "Approve", "Post as comment".
    static func primaryTitle(_ draft: ReviewDraft, excluded: Set<Int> = []) -> String {
        let lines = included(draft, excluded: excluded).count
        let suffix = lines > 0 ? " \u{00B7} \(lines) comment\(lines == 1 ? "" : "s")" : ""
        switch draft.verdict {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes" + suffix
        case .comment: return "Post as comment" + suffix
        }
    }

    struct Alternative: Equatable, Identifiable {
        enum Kind: Equatable { case action(ReviewAction), summaryOnly }
        let kind: Kind
        let title: String
        /// Set when posting this goes against what the reviewer recommended.
        let note: String?
        var id: String { title }
    }

    /// The other ways to post it, each saying when it overrides the reviewer.
    static func alternatives(_ draft: ReviewDraft) -> [Alternative] {
        var list: [Alternative] = []
        for action in [ReviewAction.approve, .requestChanges, .postComments] where action != primary(draft) {
            guard draft.problem(for: action) == nil else { continue }
            let title: String
            switch action {
            case .approve: title = "Approve anyway"
            case .requestChanges: title = "Request changes"
            case .postComments: title = "Comment instead"
            }
            list.append(Alternative(kind: .action(action), title: title, note: override(action, draft)))
        }
        if !draft.comments.isEmpty, draft.verdict != .approve, !ReviewDraft.untagged(draft.summary).isEmpty {
            list.append(Alternative(kind: .summaryOnly, title: "Post summary only", note: nil))
        }
        return list
    }

    /// "Reviewer recommends approve", when posting `action` is not what the review recommends.
    static func override(_ action: ReviewAction, _ draft: ReviewDraft) -> String? {
        switch action {
        case .approve: return draft.verdict == .approve ? nil : "Reviewer recommends \(draft.verdict.title.lowercased())"
        case .requestChanges: return draft.verdict == .approve ? "Reviewer recommends approve" : nil
        case .postComments: return nil
        }
    }

    /// What a click posts, for the line under the button: "Posts 1 review + 3 line comments to orbit.api#12".
    static func preview(_ draft: ReviewDraft, action: ReviewAction, summaryOnly: Bool = false, excluded: Set<Int> = []) -> String {
        let noun: String
        switch action {
        case .approve: noun = "approval"
        case .requestChanges: noun = "review asking for changes"
        case .postComments: noun = "review comment"
        }
        let lines = action == .approve || summaryOnly ? 0 : included(draft, excluded: excluded).count
        return "Posts 1 \(noun)" + (lines > 0 ? " + \(lines) line comment\(lines == 1 ? "" : "s")" : "") + " to \(draft.reference)"
    }

    // MARK: Which comments go

    static func included(_ draft: ReviewDraft, excluded: Set<Int>) -> [ReviewDraft.Comment] {
        draft.comments.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    /// The draft as it is posted when the user took some comments out.
    static func applying(_ draft: ReviewDraft, excluded: Set<Int>) -> ReviewDraft {
        guard !excluded.isEmpty else { return draft }
        var copy = draft
        copy.comments = included(draft, excluded: excluded)
        return copy
    }

    static func summaryOnly(_ draft: ReviewDraft) -> ReviewDraft {
        var copy = draft
        copy.comments = []
        return copy
    }

    // MARK: State

    enum State: Equatable {
        case ready, posting, waiting
        case posted(String)
        case failed(String, ReviewAction)
    }

    static func state(working: Bool, waiting: Bool, posted: ReviewPosted?, result: String?) -> State {
        if working { return .posting }
        if waiting { return .waiting }
        guard let posted else { return .ready }
        return posted.ok ? .posted(posted.text) : .failed(result ?? posted.text, posted.action)
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }
}

/// The notices of drafted reviews: one row per pull request, a newer draft replacing an older one.
enum ReviewBoard {
    struct Outcome: Equatable {
        var notices: [AgentNotice]
        /// The notices that held only superseded drafts and are gone.
        var removed: [String]
        /// The notices that stay with fewer drafts.
        var changed: [String]
    }

    /// Takes the drafts of the same pull requests out of the notices already there, so a pull request never has two rows.
    static func supersede(_ notices: [AgentNotice], by drafts: [ReviewDraft]) -> Outcome {
        let addresses = Set(drafts.map(\.pr))
        var outcome = Outcome(notices: [], removed: [], changed: [])
        for var notice in notices {
            guard let reviews = notice.reviews else { outcome.notices.append(notice); continue }
            let rest = reviews.filter { !addresses.contains($0.pr) }
            if rest.count == reviews.count { outcome.notices.append(notice); continue }
            guard !rest.isEmpty else { outcome.removed.append(notice.id); continue }
            notice.reviews = rest
            notice.title = ReviewNotices.title(for: rest)
            notice.body = ReviewNotices.body(for: rest)
            notice.link = rest.count == 1 ? rest[0].pr : notice.source.agent
            outcome.notices.append(notice)
            outcome.changed.append(notice.id)
        }
        return outcome
    }

    /// Whether "Approve all" is worth offering: more than one, and every review recommends approving.
    static func canApproveAll(_ drafts: [ReviewDraft]) -> Bool {
        drafts.count > 1 && drafts.allSatisfy { $0.verdict == .approve }
    }
}
