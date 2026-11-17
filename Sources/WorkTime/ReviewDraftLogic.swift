import Foundation

/// A review an agent drafted and did not post: the pull request, the commit it looked at, a verdict, a summary and comments on
/// lines. The agent writes it as a `worktime-review` block; only the user's click posts it.
struct ReviewDraft: Codable, Equatable, Identifiable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case approve, requestChanges = "request_changes", comment

        init?(text: String) {
            switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
            case "approve", "approved", "lgtm": self = .approve
            case "request_changes", "changes_requested", "request_change", "changes", "reject": self = .requestChanges
            case "comment", "comments", "commented": self = .comment
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .approve: return "Approve"
            case .requestChanges: return "Request changes"
            case .comment: return "Comment"
            }
        }
    }

    struct Comment: Codable, Equatable, Sendable {
        var path: String
        var line: Int
        var body: String
        /// The first line of a comment on several lines, when the agent gave one.
        var startLine: Int?
    }

    var pr: String
    var sha: String?
    var verdict: Verdict
    var summary: String
    var comments: [Comment]

    /// The same for the same review of the same commit, so a posted review stays posted and a repeat replaces its notification.
    var id: String { pr + "@" + (sha.map { String($0.prefix(12)).lowercased() } ?? "") }
    var target: GitHubLink.Target? { GitHubLink.pullRequest(at: pr) }
    var reference: String { target.map { "\(GitHubLogic.repoName($0.repo).name)#\($0.number)" } ?? pr }
}

/// What the user can post a draft as.
enum ReviewAction: String, Codable, CaseIterable, Sendable {
    case approve, requestChanges = "request_changes", postComments = "post_comments"

    var title: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .postComments: return "Post comments"
        }
    }

    var action: GitHubAction {
        switch self {
        case .approve: return .approve
        case .requestChanges: return .requestChanges
        case .postComments: return .comment
        }
    }
}

enum ReviewDrafts {
    static let info = "worktime-review"
    static let summaryLimit = 6000
    static let commentLimit = 40
    static let commentBodyLimit = 2000
    static let tag = "[AI]"

    /// What an agent that reviews a pull request is told about writing its draft so the app can offer to post it: the built-in text of the
    /// Review draft format template, which a prompt takes from the user's own file for its workspace.
    static let instructions = PromptBuiltIns.reviewDraftFormat.trimmingCharacters(in: .whitespacesAndNewlines)

    // MARK: Reading

    /// The draft one `worktime-review` block holds: JSON, or failing that `pr:`, `sha:`, `verdict:` and `summary:` lines.
    /// Nil when it names no pull request or no verdict.
    static func parse(block: String) -> ReviewDraft? {
        let text = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return draft(from: object) }
        return lenient(text)
    }

    private static func draft(from object: [String: Any]) -> ReviewDraft? {
        func string(_ keys: [String]) -> String? {
            keys.lazy.compactMap { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        guard let address = string(["pr", "url", "pull_request"]), let target = GitHubLink.pasted(address),
              let verdict = string(["verdict", "decision", "event"]).flatMap({ ReviewDraft.Verdict(text: $0) }) else { return nil }
        let comments = (object["comments"] as? [[String: Any]] ?? []).compactMap(comment).prefix(commentLimit)
        return ReviewDraft(pr: target.url, sha: string(["sha", "commit", "head_sha", "head"]).flatMap(commit), verdict: verdict,
                           summary: clipped(string(["summary", "body", "review"]) ?? "", summaryLimit), comments: Array(comments))
    }

    private static func comment(_ object: [String: Any]) -> ReviewDraft.Comment? {
        func string(_ keys: [String]) -> String? {
            keys.lazy.compactMap { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        }
        func number(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = object[key] as? Int { return value }
                if let text = object[key] as? String, let value = integer(text) { return value }
            }
            return nil
        }
        guard let path = string(["file", "path"]), let line = number(["line", "end_line"]), line > 0, let body = string(["body", "text", "comment"]) else { return nil }
        let start = number(["start_line", "line_start"]).flatMap { $0 > 0 && $0 < line ? $0 : nil }
        return ReviewDraft.Comment(path: path, line: line, body: clipped(body, commentBodyLimit), startLine: start)
    }

    /// A whole number written as text, also when the writer grouped the digits (`1 290`, `1,290`).
    static func integer(_ text: String) -> Int? {
        Int(String(text.filter { $0.isNumber || $0 == "-" }))
    }

    /// A block that is not JSON: the keys it states, and what follows `summary:` as the summary. No comments are read from it.
    private static func lenient(_ text: String) -> ReviewDraft? {
        var values: [String: String] = [:]
        var summary: [String] = []
        var inSummary = false
        for line in text.components(separatedBy: "\n") {
            if let (key, rest) = keyLine(line), key != "summary" || !inSummary {
                inSummary = key == "summary"
                if inSummary { if !["|", ">", ""].contains(rest) { summary.append(rest) } } else { values[key] = rest }
            } else if inSummary {
                summary.append(line)
            }
        }
        guard let address = values["pr"], let target = GitHubLink.pasted(address), let verdict = values["verdict"].flatMap({ ReviewDraft.Verdict(text: $0) }) else { return nil }
        let body = summary.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ReviewDraft(pr: target.url, sha: values["sha"].flatMap(commit), verdict: verdict, summary: clipped(body, summaryLimit), comments: [])
    }

    private static func keyLine(_ line: String) -> (key: String, rest: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard ["pr", "sha", "verdict", "summary"].contains(key) else { return nil }
        return (key, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func commit(_ text: String) -> String? {
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (7...40).contains(sha.count) && sha.allSatisfy(\.isHexDigit) ? sha : nil
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }

    /// Every well-formed block of a reply, in order; a later block for the same pull request replaces the earlier one.
    static func drafts(in text: String) -> [ReviewDraft] {
        var drafts: [ReviewDraft] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            guard let fence = AgentActions.opening(lines[index].trimmingCharacters(in: .whitespaces)) else { index += 1; continue }
            let end = lines[(index + 1)...].firstIndex { AgentActions.isClosing($0.trimmingCharacters(in: .whitespaces), of: fence.marker) }
            if fence.info == info, let end, let draft = parse(block: lines[(index + 1)..<end].joined(separator: "\n")) {
                if let same = drafts.firstIndex(where: { $0.pr == draft.pr }) { drafts[same] = draft } else { drafts.append(draft) }
            }
            index = (end ?? index) + 1
        }
        return drafts
    }

    /// The drafts in what the agent wrote since the user's last message.
    static func drafts(inTurn items: [AgentItem]) -> [ReviewDraft] {
        let lastPrompt = items.lastIndex { if case .user = $0.kind { true } else { false } }
        let text = items[(lastPrompt.map { $0 + 1 } ?? 0)...].compactMap { item -> String? in
            if case .text(let text) = item.kind { text } else { nil }
        }.joined(separator: "\n\n")
        return drafts(in: text)
    }
}

// MARK: Posting

extension ReviewDraft {
    /// The draft's text as posted: every body starts with the tag that says an agent wrote it.
    static func tagged(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.hasPrefix(ReviewDrafts.tag) ? text : ReviewDrafts.tag + " " + text
    }

    /// The comments that go on lines: with a request for changes or a plain comment, not with an approval.
    func inline(for action: ReviewAction) -> [Comment] { action == .approve ? [] : comments }

    /// The review's body for this action: the summary with the comments GitHub cannot place under it, or a pointer to the comments when
    /// only they are there.
    func body(for action: ReviewAction, moved: [ReviewAnchors.Moved] = [], anchored: Int? = nil) -> String {
        let text = ReviewDraft.tagged(summary)
        if action != .approve, !moved.isEmpty { return ReviewDraft.tagged(ReviewAnchors.foldedBody(ReviewDraft.untagged(text), moved: moved)) }
        if !text.isEmpty || action == .approve { return text }
        return (anchored ?? comments.count) == 0 ? "" : ReviewDraft.tagged("See the comments on the lines.")
    }

    /// Why this cannot be posted as `action`, nil when it can.
    func problem(for action: ReviewAction) -> String? {
        if action != .approve, body(for: action).isEmpty { return "The review has nothing to post." }
        if action == .postComments, comments.isEmpty, summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The review has nothing to post." }
        return nil
    }

    /// The request the page's own code runs: the review as it will be posted, on the commit it covers.
    func request(_ action: ReviewAction, pr: GitHubPR, commit: String?, actor: String?, via: String?, plan: ReviewAnchors.Plan? = nil) -> GitHubActionRequest {
        var request = GitHubActionRequest(action.action, pr: pr)
        let placed = plan.map { action == .approve ? [] : $0.anchored } ?? inline(for: action)
        request.comment = body(for: action, moved: plan?.moved ?? [], anchored: placed.count)
        request.inline = placed.map { Comment(path: $0.path, line: $0.line, body: ReviewDraft.tagged($0.body), startLine: $0.startLine) }
        request.commitID = commit
        request.actor = actor
        request.via = via
        return request
    }
}

/// Whether a draft is posted with one click or has to go through the page's confirmation, and why.
enum ReviewApproval {
    enum Route: Equatable {
        case post
        /// The page's confirmation sheet opens with these reasons shown.
        case confirm([String])
        /// Nothing can be posted from here; the pull request opens instead.
        case blocked(String)
    }

    /// `oneClick` is the Settings switch; `currentSHA` is the pull request's newest commit as just fetched, `stateKnown` whether that fetch worked.
    static func route(_ action: ReviewAction, draft: ReviewDraft, target: GitHubActionTarget, request: GitHubActionRequest, currentSHA: String?,
                      stateKnown: Bool, enabled: Bool, oneClick: Bool) -> Route {
        guard enabled else { return .blocked(GitHubActions.disabledHelp) }
        if let problem = draft.problem(for: action) { return .blocked(problem) }
        let warnings: [String]
        switch GitHubActions.preflight(request, target) {
        case .blocked(let reason): return .blocked(reason)
        case .allowed(let found): warnings = found
        }
        guard oneClick else { return .confirm([GitHubActions.oneClickOffText]) }
        var reasons: [String] = []
        if !stateKnown { reasons.append("Could not check the pull request's current state.") }
        if let problem = commitProblem(reviewed: draft.sha, current: currentSHA) { reasons.append(problem) }
        if let mismatch = verdictProblem(action, draft.verdict) { reasons.append(mismatch) }
        reasons += warnings
        return reasons.isEmpty ? .post : .confirm(reasons)
    }

    private static func verdictProblem(_ action: ReviewAction, _ verdict: ReviewDraft.Verdict) -> String? {
        switch action {
        case .approve: return verdict == .approve ? nil : "The review recommends \(verdict.title.lowercased()), not approval."
        case .requestChanges: return verdict == .approve ? "The review recommends approving, not requesting changes." : nil
        case .postComments: return nil
        }
    }

    /// Why the commit does not match what the review looked at, nil when it does.
    static func commitProblem(reviewed: String?, current: String?) -> String? {
        guard let reviewed, !reviewed.isEmpty else { return "The review does not say which commit it covers." }
        guard let current, !current.isEmpty else { return "Could not read the pull request's current commit." }
        return sameCommit(reviewed, current) ? nil : "The pull request changed after the review: it covered \(short(reviewed)), the branch is now at \(short(current))."
    }

    /// Both are at least seven characters and one starts with the other, so a short sha matches the full one.
    static func sameCommit(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a.count >= 7 && b.count >= 7 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    static func short(_ sha: String) -> String { String(sha.prefix(7)) }
}

/// What a click on a button came to.
enum ReviewOutcome: Equatable, Sendable {
    case posted(String)
    case failed(String)
    /// The page's confirmation opened, with the reasons.
    case confirming(String)
    /// The pull request opened instead of posting, with the reason.
    case opened(String)

    var text: String {
        switch self {
        case .posted(let text), .failed(let text), .confirming(let text), .opened(let text): return text
        }
    }

    var posted: Bool { if case .posted = self { true } else { false } }
}

/// The notification of a drafted review: its title, its buttons and what is left of it as drafts are posted.
enum ReviewNotices {
    enum Button: String, CaseIterable, Sendable {
        case approve = "review-post-approve", changes = "review-post-changes", comments = "review-post-comments", approveAll = "review-post-all"
        case open = "review-draft-open", dismiss = "review-draft-dismiss", confirmAll = "review-confirm-all", cancelAll = "review-cancel-all"
    }

    static let confirmPrefix = "review-confirm-"
    static let bodyLimit = 400

    /// The buttons of a notification: for one pull request the one click that posts the review as the reviewer drafted it, with Open; a set
    /// is approved all at once after a second look, and only when every review recommends approving.
    static func buttons(for drafts: [ReviewDraft]) -> [Button] {
        guard drafts.count == 1, let draft = drafts.first else {
            return (ReviewBoard.canApproveAll(drafts) ? [.approveAll] : []) + [.open, .dismiss]
        }
        let primary: Button
        switch ReviewRows.primary(draft) {
        case .approve: primary = .approve
        case .requestChanges: primary = .changes
        case .postComments: primary = .comments
        }
        return (draft.problem(for: ReviewRows.primary(draft)) == nil ? [primary] : []) + [.open, .dismiss]
    }

    static func category(for drafts: [ReviewDraft]) -> String { category(buttons(for: drafts)) }

    static func category(_ buttons: [Button]) -> String { "review-draft:" + buttons.map(\.rawValue).joined(separator: ",") }

    /// Every set of buttons a notification can have, for the system to know them up front.
    static var allButtonSets: [[Button]] {
        let firsts: [Button?] = [.approve, .changes, .comments, .approveAll, nil]
        return firsts.map { first in (first.map { [$0] } ?? []) + [.open, .dismiss] }
    }

    static func action(_ button: Button) -> ReviewAction? {
        switch button {
        case .approve: return .approve
        case .changes: return .requestChanges
        case .comments: return .postComments
        default: return nil
        }
    }

    static func title(for drafts: [ReviewDraft]) -> String {
        guard drafts.count == 1, let draft = drafts.first else { return "Review ready: \(drafts.count) pull requests" }
        return "Review ready: \(draft.reference) \u{00B7} \(draft.verdict.title.lowercased())"
    }

    /// The two lines of a notification about one review: why, and what is in it. A set gets one line per pull request.
    static func body(for drafts: [ReviewDraft]) -> String {
        guard drafts.count == 1, let draft = drafts.first else {
            return drafts.map { draft in
                let reason = ReviewRows.reason(draft, limit: 70)
                return "\(draft.reference) \u{00B7} \(draft.verdict.title.lowercased())" + (reason.isEmpty ? "" : " \u{2014} " + reason)
            }.joined(separator: "\n")
        }
        let text = [ReviewRows.reason(draft), ReviewRows.counts(draft)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return ReviewRows.clipped(text, bodyLimit)
    }

    static func notice(drafts: [ReviewDraft], agent: String, agentTitle: String, id: String = UUID().uuidString, now: Date) -> AgentNotice {
        AgentNotice(id: id, title: title(for: drafts), body: body(for: drafts), link: drafts.count == 1 ? drafts[0].pr : agent, urgency: .high,
                    source: NoticeSource(agent: agent, title: agentTitle), created: now, reviews: drafts)
    }

    /// The notification after a draft was posted: what is left to post, or the result when nothing is.
    static func afterPosting(_ notice: AgentNotice, draft: ReviewDraft, text: String) -> AgentNotice {
        var notice = notice
        let rest = (notice.reviews ?? []).filter { $0.id != draft.id }
        if rest.isEmpty {
            let parts = text.components(separatedBy: " \u{00B7} ")
            notice.title = parts[0]
            notice.body = parts.dropFirst().joined(separator: " \u{00B7} ")
            notice.reviews = nil
            notice.urgency = .normal
            notice.link = draft.pr
        } else {
            notice.reviews = rest
            notice.title = title(for: rest)
            notice.body = body(for: rest)
            notice.link = rest.count == 1 ? rest[0].pr : notice.source.agent
        }
        return notice
    }

    /// The notification after several were approved at once: what is left, or the result when everything was approved.
    static func afterApproving(_ notice: AgentNotice, results: [(draft: ReviewDraft, outcome: ReviewOutcome)]) -> AgentNotice {
        var notice = notice
        let rest = results.filter { !$0.outcome.posted }.map(\.draft)
        let text = summary(results)
        if rest.isEmpty {
            notice.title = text
            notice.body = nil
            notice.reviews = nil
            notice.urgency = .normal
            notice.link = nil
        } else {
            notice.reviews = rest
            notice.title = title(for: rest)
            notice.body = text
            notice.link = rest.count == 1 ? rest[0].pr : notice.source.agent
        }
        return notice
    }

    /// The notification after a post failed: it stays, with why.
    static func afterFailure(_ notice: AgentNotice, text: String) -> AgentNotice {
        var notice = notice
        notice.body = text
        return notice
    }

    static func confirmTitle(_ drafts: [ReviewDraft]) -> String { "Approve \(drafts.count) pull request\(drafts.count == 1 ? "" : "s")?" }

    static func confirmBody(_ drafts: [ReviewDraft]) -> String { drafts.map(\.reference).joined(separator: ", ") }

    static func confirmIdentifier(_ id: String) -> String { confirmPrefix + id }

    /// "Approved 2 of 3", then what went wrong.
    static func summary(_ outcomes: [(draft: ReviewDraft, outcome: ReviewOutcome)]) -> String {
        let done = outcomes.filter { $0.outcome.posted }.count
        var lines = ["Approved \(done) of \(outcomes.count)"]
        for (draft, outcome) in outcomes where !outcome.posted { lines.append("\(draft.reference): \(outcome.text)") }
        return lines.joined(separator: "\n")
    }
}

/// The reviews already posted or tried, by draft, kept between runs of the app so a card says what became of it.
struct ReviewPosted: Codable, Equatable {
    var action: ReviewAction
    var text: String
    var ok: Bool
    var date: Date
}

enum ReviewPostedBook {
    typealias Book = [String: ReviewPosted]
    static let limit = 200

    static func record(_ posted: ReviewPosted, draft: String, in book: Book) -> Book {
        var book = book
        book[draft] = posted
        let extra = book.count - limit
        if extra > 0 { for old in book.sorted(by: { $0.value.date < $1.value.date }).prefix(extra) { book[old.key] = nil } }
        return book
    }

    static func encode(_ book: Book) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(book)
    }

    static func decode(_ data: Data?) -> Book {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.flatMap { try? decoder.decode(Book.self, from: $0) } ?? [:]
    }
}
