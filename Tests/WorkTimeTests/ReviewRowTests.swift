import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let one = "https://github.com/acme/orbit.api/pull/12"
private let two = "https://github.com/acme/orbit.api/pull/13"
private let at = Date(timeIntervalSince1970: 1_792_300_000)
private let utc = TimeZone(identifier: "UTC")!

private func comment(_ path: String = "sync.py", _ line: Int = 4, _ body: String = "Order by id.") -> ReviewDraft.Comment {
    ReviewDraft.Comment(path: path, line: line, body: body)
}

private func draft(_ verdict: ReviewDraft.Verdict = .requestChanges, pr: String = one, sha: String? = "0123456", summary: String = "[AI] The sync drops rows. Fix the order first. Then it is fine.",
                   comments: [ReviewDraft.Comment] = []) -> ReviewDraft {
    ReviewDraft(pr: pr, sha: sha, verdict: verdict, summary: summary, comments: comments)
}

private func notice(_ id: String, _ drafts: [ReviewDraft]) -> AgentNotice {
    ReviewNotices.notice(drafts: drafts, agent: "assistant:work:reviewer", agentTitle: "Reviewer", id: id, now: at)
}

let reviewRowTests: [(name: String, run: () throws -> Void)] = [
    ("review rows: the reason is the first two sentences of the summary, without the tag, on one line", {
        check(ReviewRows.reason(draft()) == "The sync drops rows. Fix the order first.", ReviewRows.reason(draft()))
        check(ReviewRows.reason(draft(summary: "One sentence only")) == "One sentence only", "no full stop")
        check(ReviewRows.reason(draft(summary: "See api.py:7 now.\nSecond line here. Third.")) == "See api.py:7 now. Second line here.", "a file name is not a sentence end")
        check(ReviewRows.reason(draft(summary: String(repeating: "word ", count: 80)), limit: 40).count == 40, "clipped to the limit")
        check(ReviewRows.reason(draft(summary: "")) == "", "empty")
    }),

    ("review rows: the counts name the blocking comments and the lines, the first comment is the blocking one when changes are asked for", {
        let comments = [comment("a.py", 1, "Naming."), comment("b.py", 2, "This will fail on empty input."), comment("c.py", 3, "Must not drop the index.")]
        let review = draft(comments: comments)
        check(ReviewRows.counts(review) == "2 blocking \u{00B7} 3 comments on lines", "\(String(describing: ReviewRows.counts(review)))")
        check(ReviewRows.counts(draft(comments: [comment()])) == "1 comment on lines", "one, none blocking")
        check(ReviewRows.counts(draft()) == nil, "no comments")
        check(ReviewRows.firstComment(review) == "b.py:2 \u{2014} This will fail on empty input.", "\(String(describing: ReviewRows.firstComment(review)))")
        check(ReviewRows.firstComment(draft(.comment, comments: comments)) == "a.py:1 \u{2014} Naming.", "the first for a plain comment")
        check(ReviewRows.firstComment(draft(comments: [comment("sync.py", 4, String(repeating: "x", count: 300))]))!.count <= ReviewRows.commentLimit + 12, "clipped")
        check(ReviewRows.firstComment(draft()) == nil, "none")
    }),

    ("review rows: the main button is named for the draft's own verdict and the others say when they override it", {
        let comments = [comment(), comment("b.py", 2, "Name it.")]
        check(ReviewRows.primary(draft(.approve)) == .approve && ReviewRows.primary(draft(.requestChanges)) == .requestChanges && ReviewRows.primary(draft(.comment)) == .postComments, "verdict to action")
        check(ReviewRows.primaryTitle(draft(.approve)) == "Approve", "approve")
        check(ReviewRows.primaryTitle(draft(.requestChanges, comments: comments)) == "Request changes \u{00B7} 2 comments", "request changes with comments")
        check(ReviewRows.primaryTitle(draft(.requestChanges, comments: comments), excluded: [1]) == "Request changes \u{00B7} 1 comment", "one taken out")
        check(ReviewRows.primaryTitle(draft(.comment)) == "Post as comment", "comment")
        let alternatives = ReviewRows.alternatives(draft(.requestChanges, comments: comments))
        check(alternatives.map(\.title) == ["Approve anyway", "Comment instead", "Post summary only"], alternatives.map(\.title).joined(separator: ", "))
        check(alternatives[0].note == "Reviewer recommends request changes" && alternatives[1].note == nil, "overrides are named")
        let fromApprove = ReviewRows.alternatives(draft(.approve))
        check(fromApprove.map(\.title) == ["Request changes", "Comment instead"] && fromApprove[0].note == "Reviewer recommends approve", "\(fromApprove.map(\.title))")
        check(ReviewRows.alternatives(draft(.requestChanges, summary: "")).map(\.title) == ["Approve anyway"], "an approval needs no text, a comment does")
    }),

    ("review rows: the preview says exactly what a click posts", {
        let comments = [comment(), comment("b.py", 2, "Name it."), comment("c.py", 3, "Test it.")]
        let review = draft(.requestChanges, comments: comments)
        check(ReviewRows.preview(review, action: .requestChanges) == "Posts 1 review asking for changes + 3 line comments to orbit.api#12", ReviewRows.preview(review, action: .requestChanges))
        check(ReviewRows.preview(review, action: .requestChanges, excluded: [0, 2]) == "Posts 1 review asking for changes + 1 line comment to orbit.api#12", "taken out")
        check(ReviewRows.preview(review, action: .approve) == "Posts 1 approval to orbit.api#12", "an approval carries no line comments")
        check(ReviewRows.preview(review, action: .postComments, summaryOnly: true) == "Posts 1 review comment to orbit.api#12", "summary only")
    }),

    ("review rows: comments taken out do not go, summary only goes without any", {
        let comments = [comment(), comment("b.py", 2, "Name it."), comment("c.py", 3, "Test it.")]
        let review = draft(comments: comments)
        check(ReviewRows.applying(review, excluded: [1]).comments.map(\.path) == ["sync.py", "c.py"], "the second is out")
        check(ReviewRows.applying(review, excluded: []) == review && ReviewRows.applying(review, excluded: [0, 1, 2]).comments.isEmpty, "none taken out, all taken out")
        check(ReviewRows.applying(review, excluded: [1]).id == review.id, "the same review")
        check(ReviewRows.summaryOnly(review).comments.isEmpty && ReviewRows.summaryOnly(review).summary == review.summary, "summary only")
    }),

    ("review rows: the state is posting, waiting, posted or failed with the action to retry, otherwise ready", {
        let ok = ReviewPosted(action: .approve, text: "Approved", ok: true, date: at)
        let bad = ReviewPosted(action: .requestChanges, text: "GitHub said no", ok: false, date: at)
        check(ReviewRows.state(working: true, waiting: false, posted: ok, result: nil) == .posting, "posting wins")
        check(ReviewRows.state(working: false, waiting: true, posted: nil, result: nil) == .waiting, "waiting for the checks")
        check(ReviewRows.state(working: false, waiting: false, posted: ok, result: nil) == .posted("Approved"), "posted")
        check(ReviewRows.state(working: false, waiting: false, posted: bad, result: "Validation Failed") == .failed("Validation Failed", .requestChanges), "failed with its reason and action")
        check(ReviewRows.state(working: false, waiting: false, posted: bad, result: nil) == .failed("GitHub said no", .requestChanges), "the recorded text")
        check(ReviewRows.state(working: false, waiting: false, posted: nil, result: "Opened") == .ready, "nothing posted")
    }),

    ("review board: a newer draft of a pull request replaces the older one, never a second row", {
        let older = notice("a", [draft(.comment, sha: "1111111")])
        let other = notice("b", [draft(.approve, pr: two)])
        let outcome = ReviewBoard.supersede([older, other], by: [draft(.requestChanges, sha: "2222222")])
        check(outcome.removed == ["a"] && outcome.notices.map(\.id) == ["b"] && outcome.changed.isEmpty, "the old one goes: \(outcome.removed)")
        let set = notice("s", [draft(.approve), draft(.approve, pr: two)])
        let part = ReviewBoard.supersede([set], by: [draft(.requestChanges, sha: "3333333")])
        check(part.removed.isEmpty && part.changed == ["s"] && part.notices[0].reviews?.map(\.pr) == [two], "a set keeps the other")
        check(part.notices[0].title == "Review ready: orbit.api#13 \u{00B7} approve" && part.notices[0].link == two, "\(part.notices[0].title)")
        let plain = AgentNotice(id: "p", title: "Hello", source: NoticeSource(agent: "k"), created: at)
        check(ReviewBoard.supersede([plain], by: [draft()]).notices == [plain], "other notices stay")
        check(ReviewBoard.canApproveAll([draft(.approve), draft(.approve, pr: two)]) && !ReviewBoard.canApproveAll([draft(.approve)]) && !ReviewBoard.canApproveAll([draft(.approve), draft(.comment, pr: two)]), "approve all")
    }),

    ("review hunks: the lines around a comment's line, marked, from the patch", {
        let patch = "@@ -1,4 +10,5 @@ def sync\n context a\n-old line\n+new line b\n+new line c\n context d\n@@ -40,2 +50,2 @@\n later one\n+later two"
        let found = ReviewHunks.excerpt(patch: patch, line: 12, context: 1)
        check(found == "  +new line b\n\u{25B6} +new line c\n  context d" || found == "  +new line b\n\u{25B6} +new line c\n   context d", "\(String(describing: found))")
        check(ReviewHunks.excerpt(patch: patch, line: 51, context: 1)?.contains("\u{25B6} +later two") == true, "the second hunk")
        check(ReviewHunks.excerpt(patch: patch, line: 30) == nil, "a line in no hunk")
        check(ReviewHunks.excerpt(patch: patch, line: 12, context: 5, limit: 3)?.components(separatedBy: "\n").count == 3, "limited")
    }),

    ("decision detail: a review's sections tell who, what, the checks and the reasoning", {
        var detail = GitHubPRDetail(url: one, repo: "acme/orbit.api", number: 12, title: "ACME-9: Fix the sync")
        detail.body = "Drops nothing now."
        detail.head = "NI/ACME-9"
        detail.base = "develop"
        detail.headOid = "0123456789abcdef"
        detail.checks = [.init(name: "unit", status: .passed), .init(name: "lint", workflow: "ci", status: .failed), .init(name: "build", status: .running)]
        let info = ReviewPRInfo(title: "ACME-9: Fix the sync", author: "elin", additions: 10, deletions: 2, checks: .failed)
        let sections = DecisionDetail.review(draft: draft(sha: "0123456"), info: info, detail: detail, agent: "Reviewer", date: at, timeZone: utc)
        check(sections.map(\.heading) == ["Who and when", "Pull request", "Description", "Linked ticket", "Checks", "The reviewer's reasoning"], sections.map(\.heading).joined(separator: ", "))
        check(sections[0].text == "Drafted by Reviewer at 05:06, on commit 0123456", sections[0].text)
        check(sections[1].text == "orbit.api#12 ACME-9: Fix the sync\nelin \u{00B7} +10/\u{2212}2 \u{00B7} checks failing\nNI/ACME-9 \u{2192} develop", sections[1].text)
        check(sections[3].text == "ACME-9", "the ticket")
        check(sections[4].text == "\u{2717} ci / lint\n\u{2026} build\n\u{2713} unit", "failing first: \(sections[4].text)")
        let bare = DecisionDetail.review(draft: draft(sha: nil), info: ReviewPRInfo(), detail: nil, agent: nil, date: nil, timeZone: utc)
        check(bare.map(\.heading) == ["Who and when", "Pull request", "The reviewer's reasoning"] && bare[0].text == "Drafted by an agent" && bare[1].text == "orbit.api#12", "nothing known: \(bare.map(\.heading))")
        let moved = DecisionDetail.review(draft: draft(sha: "0123456"), info: info, detail: { var d = detail; d.headOid = "ffffffffff"; return d }(), agent: "R", date: nil, timeZone: utc)
        check(moved[1].text.contains("changed after the review"), "a moved commit is said")
    }),

    ("decision detail: the checks list is capped and an approval shows its call and why", {
        let many = (1...15).map { GitHubPRDetail.Check(name: "job \($0)", status: .passed) }
        let text = DecisionDetail.checkLines(many)
        check(text.components(separatedBy: "\n").count == DecisionDetail.checkLimit + 1 && text.hasSuffix("and 3 more"), "capped")
        let facts = ApprovalFacts(agent: "Reviewer", title: "Reviewer needs approval", body: "Bash: gh pr diff 12", detail: "gh pr diff 12 --patch", context: "I need the full diff to check the migration.", created: at)
        let call = DecisionDetail.approval(facts, timeZone: utc)
        check(call.map(\.heading) == ["Asked by", "Why", "The call"] && call[0].text == "Reviewer at 05:06" && call[2].monospaced && call[2].text == "gh pr diff 12 --patch", call.map(\.heading).joined(separator: ", "))
        let tool = DecisionDetail.approval(ApprovalFacts(kind: .roleTool, agent: "Verifier", title: "t", body: "Verifier wants to use jira_issue, which is not in its tools", detail: "{\"key\": \"ACME-1\"}", created: at), timeZone: utc)
        check(tool.map(\.heading) == ["Asked by", "What it wants", "The call"], tool.map(\.heading).joined(separator: ", "))
        let blocked = DecisionDetail.approval(ApprovalFacts(kind: .blocked, agent: "Verifier", title: "t", body: "short", detail: "jira_issue: not in its tools\nChrome is off", created: at), timeZone: utc)
        check(blocked.last?.heading == "What it could not do" && blocked.last?.text.contains("Chrome is off") == true, "blocked")
        let (shown, hidden) = DecisionDetail.lines("1\n2\n3\n4\n5\n6\n7\n8", limit: 6)
        check(shown == "1\n2\n3\n4\n5\n6" && hidden == 2 && DecisionDetail.lines("a\nb", limit: 6).hidden == 0, "lines")
    }),

    ("decision detail: an automation's question shows the event, the whole triage answer and what the button sends", {
        var question = AgentNotice(id: "q", title: "Review? orbit.api#7", body: "Small change.\nRecommendation: review \u{2014} money.", link: one, urgency: .high,
                                   source: NoticeSource(agent: "routine:x"), created: at)
        question.ask = NoticeAsk(routine: "R", yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: "Review {pr_url} now", reminder: nil,
                                 eventText: "Review requests\n<https://github.com/acme/orbit.api/pull/7|orbit.api#7> please")
        let sections = DecisionDetail.ask(question)
        check(sections.map(\.heading) == ["The event", "The triage answer", "Link", "\u{201C}Review it\u{201D} sends"], sections.map(\.heading).joined(separator: ", "))
        check(sections[0].text == "Review requests\norbit.api#7 please" || sections[0].text.contains("orbit.api#7 please"), "Slack markup is plain: \(sections[0].text)")
        check(sections[1].text.contains("Recommendation: review"), "the whole answer")
        check(DecisionDetail.ask(AgentNotice(id: "x", title: "t", source: NoticeSource(agent: "k"), created: at)).isEmpty, "not a question")
    }),

    ("decision rows: opening and closing a row, the keyboard focus, and forgetting rows that are gone", {
        var rows = DecisionExpansion()
        let ids = [DecisionIDs.notice("a"), DecisionIDs.review("b"), DecisionIDs.approval("c")]
        check(!rows.isExpanded(ids[0]) && rows.focus == nil, "starts closed")
        rows.moveFocus(1, in: ids)
        check(rows.focus == ids[0], "the first row takes the focus")
        rows.moveFocus(1, in: ids); rows.moveFocus(1, in: ids); rows.moveFocus(1, in: ids)
        check(rows.focus == ids[2], "stops at the last")
        rows.moveFocus(-5, in: ids)
        check(rows.focus == ids[0], "stops at the first")
        check(rows.activate() == ids[0] && rows.isExpanded(ids[0]), "Return opens the focused row")
        check(rows.activate() == ids[0] && !rows.isExpanded(ids[0]), "again closes it")
        rows.toggle(ids[1])
        check(rows.isExpanded(ids[1]) && rows.focus == ids[1], "a click opens it and focuses it")
        rows.prune(to: [ids[0], ids[2]])
        check(!rows.isExpanded(ids[1]) && rows.focus == nil, "a row that went is forgotten")
        rows.moveFocus(1, in: [])
        var empty = DecisionExpansion()
        check(rows.focus == nil && empty.activate() == nil, "no rows, nothing to open")
    }),
]
