import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fence = "```"
private let full = "0123456789abcdef0123456789abcdef01234567"
private let url = "https://github.com/acme/orbit.api/pull/12"

private func block(_ json: String) -> String { "\(fence)\(ReviewDrafts.info)\n\(json)\n\(fence)" }

private let sampleJSON = """
    {"pr": "\(url)", "sha": "0123456", "verdict": "request_changes", "summary": "The sync drops rows.",
     "comments": [{"file": "sync.py", "line": 42, "body": "Order by id."}, {"path": "api.py", "line": "7", "text": "Name it."}, {"file": "x.py", "line": 0, "body": "no"}]}
    """

private func draft(verdict: ReviewDraft.Verdict = .approve, sha: String? = "0123456", summary: String = "Looks right.",
                   comments: [ReviewDraft.Comment] = [], pr address: String = url) -> ReviewDraft {
    ReviewDraft(pr: address, sha: sha, verdict: verdict, summary: summary, comments: comments)
}

private func pullRequest(_ number: Int = 12, author: String = "elin", draft: Bool = false, checks: GitHubPR.Checks = .passed,
                         review: GitHubPR.Review? = nil, state: GitHubPR.State = .open) -> GitHubPR {
    GitHubPR(url: "https://github.com/acme/orbit.api/pull/\(number)", number: number, title: "ACME-1: Fix it", repo: "acme/orbit.api", isDraft: draft, state: state,
             updated: Date(timeIntervalSince1970: 1_792_300_000), review: review, checks: checks, author: author,
             activity: GitHubActivity(me: "niklas", authorIsBot: false, threads: 0, open: [], reviews: [], reviewCount: 0, lastComment: nil, lastCommit: nil, requested: []))
}

private func target(_ pr: GitHubPR = pullRequest(), head: String? = full) -> GitHubActionTarget {
    var target = GitHubActionTarget(pr: pr)
    target.headOid = head
    return target
}

private func route(_ action: ReviewAction = .approve, _ review: ReviewDraft = draft(), pr: GitHubPR = pullRequest(), head: String? = full, known: Bool = true,
                   enabled: Bool = true, oneClick: Bool = true) -> ReviewApproval.Route {
    let request = review.request(action, pr: pr, commit: head, actor: "niklas", via: "notification")
    return ReviewApproval.route(action, draft: review, target: target(pr, head: head), request: request, currentSHA: head, stateKnown: known, enabled: enabled, oneClick: oneClick)
}

private func route(_ review: ReviewDraft, pr: GitHubPR = pullRequest(), head: String? = full, known: Bool = true, enabled: Bool = true,
                   oneClick: Bool = true) -> ReviewApproval.Route {
    route(.approve, review, pr: pr, head: head, known: known, enabled: enabled, oneClick: oneClick)
}

private func reasons(_ route: ReviewApproval.Route) -> [String] { if case .confirm(let reasons) = route { reasons } else { [] } }

private func blocked(_ route: ReviewApproval.Route) -> String? { if case .blocked(let reason) = route { reason } else { nil } }

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let reviewDraftTests: [(name: String, run: () throws -> Void)] = [
    ("review draft: a block of JSON gives the pull request, commit, verdict, summary and the comments that have a file, a line and a text", {
        let parsed = ReviewDrafts.parse(block: sampleJSON)
        check(parsed?.pr == url && parsed?.sha == "0123456" && parsed?.verdict == .requestChanges && parsed?.summary == "The sync drops rows.", "\(String(describing: parsed))")
        check(parsed?.comments == [ReviewDraft.Comment(path: "sync.py", line: 42, body: "Order by id."), ReviewDraft.Comment(path: "api.py", line: 7, body: "Name it.")],
              "a line of 0 is dropped, a numeric string and the other key names are read: \(String(describing: parsed?.comments))")
        check(parsed?.id == url + "@0123456", "the id")
        let alias = ReviewDrafts.parse(block: "{\"url\": \"acme/orbit.api#12\", \"verdict\": \"Changes-Requested\", \"head\": \"ABCDEF1\", \"body\": \"x\"}")
        check(alias?.pr == url && alias?.verdict == .requestChanges && alias?.sha == "abcdef1", "aliases, a short pull request name and an upper case sha: \(String(describing: alias))")
        check(ReviewDraft.Verdict(text: "LGTM") == .approve && ReviewDraft.Verdict(text: "comments") == .comment && ReviewDraft.Verdict(text: "ship it") == nil, "verdict words")
    }),

    ("review draft: a block with no pull request or no verdict is not a draft, and a sha that is not hex is dropped", {
        check(ReviewDrafts.parse(block: "{\"verdict\": \"approve\"}") == nil, "no pull request")
        check(ReviewDrafts.parse(block: "{\"pr\": \"\(url)\"}") == nil, "no verdict")
        check(ReviewDrafts.parse(block: "{\"pr\": \"https://example.com/x\", \"verdict\": \"approve\"}") == nil, "not a GitHub pull request")
        check(ReviewDrafts.parse(block: "") == nil && ReviewDrafts.parse(block: "nonsense") == nil, "empty and nonsense")
        check(ReviewDrafts.parse(block: "{\"pr\": \"\(url)\", \"verdict\": \"approve\", \"sha\": \"main\"}")?.sha == nil, "main is not a commit")
        let long = ReviewDrafts.parse(block: "{\"pr\": \"\(url)\", \"verdict\": \"approve\", \"summary\": \"\(String(repeating: "x", count: 7000))\"}")
        check(long?.summary.count == ReviewDrafts.summaryLimit, "the summary is clipped")
    }),

    ("review draft: a block that is not JSON is read from its pr, sha, verdict and summary lines, without comments", {
        let text = "pr: \(url)\nsha: 0123456\nverdict: approve\nsummary: |\n  Fine.\n  Two lines.\n"
        let parsed = ReviewDrafts.parse(block: text)
        check(parsed?.pr == url && parsed?.sha == "0123456" && parsed?.verdict == .approve && parsed?.summary == "Fine.\nTwo lines." && parsed?.comments.isEmpty == true,
              "\(String(describing: parsed))")
        check(ReviewDrafts.parse(block: "verdict: approve") == nil, "still needs the pull request")
    }),

    ("review draft: the blocks of a reply are found among prose and other code, the last for a pull request wins and an unfinished one is ignored", {
        let other = "\(fence)swift\nlet a = 1\n\(fence)"
        let nested = "\(fence)\(fence)text\n\(block(sampleJSON))\n\(fence)\(fence)"
        let second = "{\"pr\": \"https://github.com/acme/orbit.api/pull/13\", \"verdict\": \"approve\", \"sha\": \"1111111\"}"
        let revised = "{\"pr\": \"\(url)\", \"verdict\": \"approve\", \"sha\": \"2222222\", \"summary\": \"Fixed.\"}"
        let reply = "I looked.\n\n\(block(sampleJSON))\n\n\(other)\n\(block(second))\nand again\n\(block(revised))"
        let drafts = ReviewDrafts.drafts(in: reply)
        check(drafts.map(\.pr) == [url, "https://github.com/acme/orbit.api/pull/13"], "\(drafts.map(\.pr))")
        check(drafts[0].verdict == .approve && drafts[0].sha == "2222222", "the later block for the same pull request replaces the earlier")
        check(ReviewDrafts.drafts(in: "\(fence)\(ReviewDrafts.info)\n\(sampleJSON)").isEmpty, "no closing fence")
        check(ReviewDrafts.drafts(in: nested).isEmpty, "a block inside a longer code block is only an example")
        check(ReviewDrafts.drafts(in: "no blocks here").isEmpty, "none")
    }),

    ("review draft: only what the agent wrote since the user's last message counts", {
        let items = [AgentItem(id: "1", kind: .text(block(sampleJSON))), AgentItem(id: "2", kind: .user("again")),
                     AgentItem(id: "3", kind: .text("thinking")), AgentItem(id: "4", kind: .text(block("{\"pr\": \"\(url)\", \"verdict\": \"comment\"}")))]
        check(ReviewDrafts.drafts(inTurn: items).map(\.verdict) == [.comment], "the turn after the last prompt")
        check(ReviewDrafts.drafts(inTurn: Array(items.prefix(2))).isEmpty, "a prompt with nothing after it")
    }),

    ("review draft: a reply's segments hold a review block as a card, also without actions, and leave a broken one as code", {
        let reply = "Here.\n\n\(block(sampleJSON))\n\nDone."
        for actions in [true, false] {
            let segments = AgentActions.segments(reply, actions: actions)
            check(segments.count == 3, "\(segments.count)")
            if case .review(let found) = segments[1] { check(found.verdict == .requestChanges, "the card") } else { check(false, "a review segment, actions \(actions)") }
        }
        let broken = AgentActions.segments("\(fence)\(ReviewDrafts.info)\n{nope\n\(fence)")
        check(broken.count == 1, "one piece")
        if case .markdown(let text) = broken[0] { check(text.contains("{nope"), "stays code") } else { check(false, "markdown") }
        let disabled = AgentActions.segments("\(fence)\(AgentActions.info)\nprompt: do it\n\(fence)", actions: false)
        if case .markdown = disabled[0] { check(true, "an action block stays code when actions are off") } else { check(false, "actions off") }
    }),

    ("review draft: the bodies posted carry the tag, an approval has no comments on lines and a pointer stands in for a missing summary", {
        let review = draft(verdict: .requestChanges, summary: "Blocks the sync.", comments: [.init(path: "a.py", line: 3, body: "Order it.")])
        check(review.body(for: .requestChanges) == "[AI] Blocks the sync.", review.body(for: .requestChanges))
        check(draft(summary: "[AI] Already tagged.").body(for: .approve) == "[AI] Already tagged.", "not tagged twice")
        check(draft(summary: "").body(for: .approve).isEmpty && draft(summary: "").problem(for: .approve) == nil, "an approval needs no text")
        check(review.inline(for: .approve).isEmpty && review.inline(for: .requestChanges).count == 1 && review.inline(for: .postComments).count == 1, "comments on lines")
        let bare = draft(verdict: .comment, summary: "", comments: [.init(path: "a.py", line: 3, body: "Order it.")])
        check(bare.body(for: .postComments) == "[AI] See the comments on the lines.", bare.body(for: .postComments))
        check(draft(verdict: .comment, summary: "").problem(for: .requestChanges) == "The review has nothing to post." && draft(summary: "").problem(for: .postComments) != nil, "nothing to post")
        let request = review.request(.requestChanges, pr: pullRequest(), commit: full, actor: "niklas", via: "notch")
        check(request.comment == "[AI] Blocks the sync." && request.inline == [.init(path: "a.py", line: 3, body: "[AI] Order it.")], "\(request.inline)")
        check(request.commitID == full && request.actor == "niklas" && request.via == "notch" && request.action == .requestChanges, "the request")
    }),

    ("review draft: a review with comments on lines goes to the review API with a file for its body, and one without stays a plain gh review", {
        let review = draft(verdict: .requestChanges, summary: "Blocks.", comments: [.init(path: "a.py", line: 3, body: "Order it.")])
        let request = review.request(.requestChanges, pr: pullRequest(), commit: full, actor: nil, via: nil)
        check(GitHubActions.arguments(request, inputFile: "/tmp/r.json") == ["api", "--method", "POST", "repos/acme/orbit.api/pulls/12/reviews", "--input", "/tmp/r.json"], "\(GitHubActions.arguments(request))")
        let payload = (try? JSONSerialization.jsonObject(with: GitHubActions.reviewPayload(request))) as? [String: Any]
        check(payload?["event"] as? String == "REQUEST_CHANGES" && payload?["commit_id"] as? String == full && payload?["body"] as? String == "[AI] Blocks.", "\(String(describing: payload))")
        let comments = payload?["comments"] as? [[String: Any]]
        check(comments?.count == 1 && comments?[0]["path"] as? String == "a.py" && comments?[0]["line"] as? Int == 3 && comments?[0]["side"] as? String == "RIGHT"
              && comments?[0]["body"] as? String == "[AI] Order it.", "\(String(describing: comments))")
        let comment = review.request(.postComments, pr: pullRequest(), commit: full, actor: nil, via: nil)
        check((try? JSONSerialization.jsonObject(with: GitHubActions.reviewPayload(comment)) as? [String: Any])?["event"] as? String == "COMMENT", "comment event")
        let approval = draft().request(.approve, pr: pullRequest(), commit: full, actor: nil, via: nil)
        check(GitHubActions.arguments(approval).first == "pr" && GitHubActions.arguments(approval).contains("--approve"), "an approval is the plain command")
        check(GitHubActions.commandLine(request) == "gh api --method POST repos/acme/orbit.api/pulls/12/reviews --input review.json", GitHubActions.commandLine(request))
        let confirmation = GitHubActions.confirmation(for: request, target: target())
        check(confirmation.facts.contains { $0.label == "Comments on lines" && $0.value == "1 on 1 file" } && confirmation.facts.contains { $0.label == "Commit" && $0.value == "0123456" },
              "the sheet shows the comments and the commit")
    }),

    ("review draft: the gh review API call reads the body from a file that is removed afterwards", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("gh")
        let script = """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--input" ]; then cp "$2" "$(dirname "$0")/seen.json"; printf '%s' "$2" > "$(dirname "$0")/path.txt"; fi
              shift
            done
            echo '{}'

            """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let review = draft(verdict: .requestChanges, summary: "Blocks.", comments: [.init(path: "a.py", line: 3, body: "It's \"odd\" $HOME")])
        let request = review.request(.requestChanges, pr: pullRequest(), commit: full, actor: nil, via: nil)
        check(GitHubActionRunner.perform(request, cli: cli) == .success("{}"), "the call worked")
        let seen = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("seen.json")))) as? [String: Any]
        check((seen?["comments"] as? [[String: Any]])?.first?["body"] as? String == "[AI] It's \"odd\" $HOME", "the text arrives unchanged: \(String(describing: seen))")
        let path = (try? String(contentsOf: directory.appendingPathComponent("path.txt"), encoding: .utf8)) ?? ""
        check(!path.isEmpty && !FileManager.default.fileExists(atPath: path), "the file is gone")
    }),

    ("review route: a clean, matching approval is posted with the click, and a short sha matches the full one", {
        check(route() == .post, "\(route())")
        check(route(draft(sha: full)) == .post && route(draft(sha: "0123456")) == .post && route(draft(sha: "0123456"), head: "0123456") == .post, "the same commit in any length")
        check(route(.postComments, draft(verdict: .comment, comments: [.init(path: "a", line: 1, body: "b")])) == .post, "comments are posted")
        check(route(.requestChanges, draft(verdict: .requestChanges, summary: "No.")) == .post, "request changes")
    }),

    ("review route: the switch off, actions off, your own, closed or nothing to post never post with one click", {
        check(route(oneClick: false) == .confirm([GitHubActions.oneClickOffText]), "the switch is off: \(route(oneClick: false))")
        check(blocked(route(enabled: false)) == GitHubActions.disabledHelp, "actions on GitHub are off")
        check(blocked(route(pr: pullRequest(author: "niklas"))) != nil, "your own pull request")
        check(blocked(route(pr: pullRequest(state: .closed))) != nil && blocked(route(pr: pullRequest(state: .merged))) != nil, "closed and merged")
        check(blocked(route(.requestChanges, draft(summary: ""))) == "The review has nothing to post.", "nothing to post")
    }),

    ("review route: a changed commit, an unknown one, a draft, failing checks or a button against the verdict need the sheet, with the reason", {
        let changed = reasons(route(head: "fedcba9876543210fedcba9876543210fedcba98"))
        check(changed.count == 1 && changed[0].contains("changed after the review") && changed[0].contains("0123456") && changed[0].contains("fedcba9"), "\(changed)")
        check(reasons(route(draft(sha: nil))) == ["The review does not say which commit it covers."], "no sha in the draft")
        check(reasons(route(head: nil)) == ["Could not read the pull request's current commit."], "no current commit")
        check(reasons(route(known: false)).contains("Could not check the pull request's current state."), "state not known")
        check(reasons(route(pr: pullRequest(draft: true))).contains("This pull request is a draft."), "a draft")
        check(reasons(route(pr: pullRequest(checks: .failed))) == [GitHubActions.checksFailing], "failing checks")
        check(reasons(route(pr: pullRequest(checks: .running))) == ["Checks are still running"], "running checks")
        check(reasons(route(pr: pullRequest(review: .changesRequested))).contains { $0.contains("Changes were requested") }, "changes requested before")
        check(reasons(route(draft(verdict: .requestChanges))) == ["The review recommends request changes, not approval."], "approving against the verdict")
        check(reasons(route(.requestChanges, draft(verdict: .approve, summary: "Fine."))) == ["The review recommends approving, not requesting changes."], "the other way")
        check(reasons(route(pr: pullRequest(checks: .failed), head: "ffffffffff")).count == 2, "every reason is listed")
        check(route(.requestChanges, draft(verdict: .requestChanges, summary: "No."), pr: pullRequest(checks: .failed)) == .post, "failing checks do not stop a request for changes")
    }),

    ("review route: the commit check", {
        check(ReviewApproval.sameCommit("0123456", full) && ReviewApproval.sameCommit(full.uppercased(), "0123456"), "prefixes match in any case")
        check(!ReviewApproval.sameCommit("012345", full) && !ReviewApproval.sameCommit("0123457", full) && !ReviewApproval.sameCommit("", ""), "too short or different")
        check(ReviewApproval.commitProblem(reviewed: "0123456", current: full) == nil, "same")
        check(ReviewApproval.short(full) == "0123456", "short")
    }),

    ("review notices: a single draft offers every button that works, a set offers approving all, and the categories cover them", {
        let single = draft(verdict: .requestChanges, summary: "No.", comments: [.init(path: "a", line: 1, body: "b")])
        check(ReviewNotices.buttons(for: [single]) == [.changes, .open, .dismiss], "a request for changes posts as one: \(ReviewNotices.buttons(for: [single]))")
        check(ReviewNotices.buttons(for: [draft()]) == [.approve, .open, .dismiss], "an approval posts as one")
        check(ReviewNotices.buttons(for: [draft(verdict: .comment, comments: [.init(path: "a", line: 1, body: "b")])]) == [.comments, .open, .dismiss], "a comment")
        check(ReviewNotices.buttons(for: [draft(verdict: .requestChanges, summary: "")]) == [.open, .dismiss], "nothing to post, so only Open")
        let set = [draft(), draft(pr: "https://github.com/acme/orbit.api/pull/13")]
        check(ReviewNotices.buttons(for: set) == [.approveAll, .open, .dismiss], "a set that recommends approving")
        check(ReviewNotices.buttons(for: [draft(), draft(verdict: .requestChanges, pr: "https://github.com/acme/orbit.api/pull/13")]) == [.open, .dismiss], "not every one approves")
        let categories = Set(ReviewNotices.allButtonSets.map(ReviewNotices.category))
        for drafts in [[single], [draft()], [draft(verdict: .requestChanges, summary: "")], set] { check(categories.contains(ReviewNotices.category(for: drafts)), "known category for \(drafts.count)") }
        check(ReviewNotices.action(.approve) == .approve && ReviewNotices.action(.changes) == .requestChanges && ReviewNotices.action(.comments) == .postComments && ReviewNotices.action(.open) == nil, "button to action")
        check(Set(ReviewNotices.Button.allCases.map(\.rawValue)).count == ReviewNotices.Button.allCases.count, "ids are distinct")
    }),

    ("review notices: the notification names the pull request and verdict, is urgent and leads to the pull request or the agent", {
        let single = draft(verdict: .requestChanges, summary: "Blocks\nthe sync.", comments: [.init(path: "a", line: 1, body: "b")])
        let notice = ReviewNotices.notice(drafts: [single], agent: "assistant:work:reviewer", agentTitle: "Reviewer", id: "n1", now: Date(timeIntervalSince1970: 100))
        check(notice.title == "Review ready: orbit.api#12 \u{00B7} request changes" && notice.body == "Blocks the sync.\n1 comment on lines", "\(notice.title) | \(String(describing: notice.body))")
        check(notice.urgency == .high && notice.link == url && notice.reviews == [single] && Decisions.needsAnswer(notice), "urgent, linked, kept until answered")
        let set = [draft(), draft(verdict: .comment, pr: "https://github.com/acme/orbit.api/pull/13")]
        let many = ReviewNotices.notice(drafts: set, agent: "agent-key", agentTitle: "Set", id: "n2", now: Date())
        check(many.title == "Review ready: 2 pull requests" && many.body == "orbit.api#12 \u{00B7} approve \u{2014} Looks right.\norbit.api#13 \u{00B7} comment \u{2014} Looks right." && many.link == "agent-key", "\(many.title) | \(String(describing: many.body))")
    }),

    ("review notices: a posted draft leaves the set, the last one turns the notification into the result and a failure keeps it with the reason", {
        let one = draft(), two = draft(pr: "https://github.com/acme/orbit.api/pull/13")
        let notice = ReviewNotices.notice(drafts: [one, two], agent: "k", agentTitle: "Set", id: "n", now: Date())
        let text = GitHubActions.successText(GitHubActionRequest(.approve, pr: pullRequest()))
        let rest = ReviewNotices.afterPosting(notice, draft: one, text: text)
        check(rest.reviews == [two] && rest.title == "Review ready: orbit.api#13 \u{00B7} approve" && rest.urgency == .high && rest.link == two.pr, "one is left: \(rest.title)")
        let done = ReviewNotices.afterPosting(rest, draft: two, text: text)
        check(done.reviews == nil && done.title == "Approved orbit.api #12" && done.body?.contains("Undo isn't possible") == true && done.urgency == .normal && !Decisions.needsAnswer(done),
              "\(done.title) | \(String(describing: done.body))")
        let failed = ReviewNotices.afterFailure(notice, text: "GitHub returned an error")
        check(failed.reviews == [one, two] && failed.body == "GitHub returned an error" && Decisions.needsAnswer(failed), "the drafts stay")
    }),

    ("review notices: approving a set at once names them, and the result says how many went and why the others did not", {
        let one = draft(), two = draft(pr: "https://github.com/acme/orbit.api/pull/13")
        check(ReviewNotices.confirmTitle([one, two]) == "Approve 2 pull requests?" && ReviewNotices.confirmBody([one, two]) == "orbit.api#12, orbit.api#13", "the question")
        check(ReviewNotices.confirmIdentifier("n") == "review-confirm-n", "identifier")
        let notice = ReviewNotices.notice(drafts: [one, two], agent: "k", agentTitle: "Set", id: "n", now: Date())
        let all = ReviewNotices.afterApproving(notice, results: [(one, .posted("ok")), (two, .posted("ok"))])
        check(all.reviews == nil && all.title == "Approved 2 of 2" && !Decisions.needsAnswer(all), "all approved: \(all.title)")
        let partly = ReviewNotices.afterApproving(notice, results: [(one, .posted("ok")), (two, .failed("Not approved: Checks are failing"))])
        check(partly.reviews == [two] && partly.body == "Approved 1 of 2\norbit.api#13: Not approved: Checks are failing" && Decisions.needsAnswer(partly), "\(String(describing: partly.body))")
    }),

    ("review notices: the same drafts replace the notification that is there, other drafts do not, and a notification with drafts survives a restart", {
        let one = draft()
        let first = ReviewNotices.notice(drafts: [one], agent: "k", agentTitle: "R", id: "a", now: Date(timeIntervalSince1970: 100))
        let again = ReviewNotices.notice(drafts: [one], agent: "k", agentTitle: "R", id: "b", now: Date(timeIntervalSince1970: 200))
        check(NoticeLogic.admit(again, existing: [first], recent: [], now: Date(timeIntervalSince1970: 200)) == .replace("a"), "replaced")
        let newer = ReviewNotices.notice(drafts: [draft(sha: "9999999")], agent: "k", agentTitle: "R", id: "c", now: Date())
        check(NoticeLogic.admit(newer, existing: [first], recent: [], now: Date()) == .add, "a review of another commit is a new one")
        let decoded = NoticeLogic.decode(NoticeLogic.encode([first]))
        check(decoded == [first] && decoded.first?.reviews == [one], "saved and read back")
        let old = "[{\"id\":\"x\",\"title\":\"t\",\"urgency\":\"normal\",\"source\":{},\"created\":\"2026-11-01T10:00:00Z\",\"state\":\"shown\"}]"
        check(NoticeLogic.decode(Data(old.utf8)).count == 1 && NoticeLogic.decode(Data(old.utf8))[0].reviews == nil, "a notification saved before has no drafts")
    }),

    ("review posted: what became of a draft is kept, and the oldest go when there are too many", {
        var book = ReviewPostedBook.Book()
        for index in 0..<(ReviewPostedBook.limit + 5) {
            book = ReviewPostedBook.record(ReviewPosted(action: .approve, text: "t", ok: true, date: Date(timeIntervalSince1970: Double(index))), draft: "d\(index)", in: book)
        }
        check(book.count == ReviewPostedBook.limit && book["d0"] == nil && book["d\(ReviewPostedBook.limit + 4)"] != nil, "\(book.count)")
        let decoded = ReviewPostedBook.decode(ReviewPostedBook.encode(book))
        check(decoded.count == book.count && decoded["d10"]?.action == .approve && decoded["d10"]?.ok == true, "kept between runs")
        check(ReviewPostedBook.decode(nil).isEmpty && ReviewPostedBook.decode(Data("junk".utf8)).isEmpty, "nothing or junk")
    }),

    ("review settings: posting from a notification needs both switches, and is off until turned on", {
        let name = "review-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        check(!GitHubActions.isReviewFromNotifications(defaults), "off by default")
        defaults.set(true, forKey: GitHubActions.reviewFromNotificationsKey)
        check(!GitHubActions.isReviewFromNotifications(defaults), "actions on GitHub are still off")
        GitHubActions.setEnabled(true, defaults)
        check(GitHubActions.isReviewFromNotifications(defaults), "both on")
        defaults.set(false, forKey: GitHubActions.reviewFromNotificationsKey)
        check(!GitHubActions.isReviewFromNotifications(defaults), "the switch off again")
    }),

    ("review log: the commit, who was signed in and where the click was are kept with the action", {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore.open(at: directory.appendingPathComponent("meetings.sqlite"))
        var request = draft().request(.approve, pr: pullRequest(), commit: full, actor: "niklas", via: "notification")
        request.comment = ""
        try store.saveGitHubAction(GitHubActionRecord(at: Date(timeIntervalSince1970: 1_792_300_000), request: request, succeeded: true))
        let plain = GitHubActionRequest(.close, pr: pullRequest())
        try store.saveGitHubAction(GitHubActionRecord(at: Date(timeIntervalSince1970: 1_792_300_100), request: plain, succeeded: false, error: "nope"))
        let records = try store.githubActions()
        check(records.count == 2 && records[1].sha == full && records[1].actor == "niklas" && records[1].via == "notification", "\(records.map { String(describing: $0.sha) })")
        check(records[0].sha == nil && records[0].actor == nil && records[0].via == nil && records[0].error == "nope", "an action without them")
        check(try store.schemaVersion() == MeetingStore.migrations.count, "migrated")
    }),

    ("review instructions: agents are told the format, the sha and that they never post", {
        let text = ReviewDrafts.instructions
        check(text.contains("```worktime-review") && text.contains("headRefOid") && text.contains("[AI]") && text.contains("never post, approve or comment yourself"), text)
        check(Assistants.templates.first { $0.role.slug == "reviewer" }?.role.body.contains("worktime-review") == true, "the Reviewer template")
        check(AutomationAsks.defaultPrompt(for: .slackChannel).contains("worktime-review") && AutomationAsks.defaultSetPrompt.contains("worktime-review"), "the default prompts")
        let set = PullRequestSets.prompt([LinkedPR(url: url)!])
        check(set.contains("worktime-review"), "the set prompt")
    }),
]
