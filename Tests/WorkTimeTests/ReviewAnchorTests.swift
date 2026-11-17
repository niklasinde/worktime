import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let patch = """
    @@ -10,4 +10,5 @@ def load():
     context a
    -old line
    +new line one
    +new line two
     context b
    @@ -40,3 +41,0 @@ def tail():
    -gone one
    -gone two
    -gone three
    @@ -60 +58,2 @@ def last():
    -old
    +fresh
    +fresher
    """

private let files = [
    DiffFile(path: "sync.py", previousPath: nil, patch: patch, status: "modified"),
    DiffFile(path: "moved/api.py", previousPath: "api.py", patch: "@@ -1,2 +1,2 @@\n a\n-b\n+c", status: "renamed"),
    DiffFile(path: "big.sql", previousPath: nil, patch: nil, status: "modified"),
    DiffFile(path: "old.py", previousPath: nil, patch: "@@ -1,2 +0,0 @@\n-a\n-b", status: "removed"),
]

private func comment(_ path: String, _ line: Int, start: Int? = nil, _ body: String = "[AI] Check this.") -> ReviewDraft.Comment {
    ReviewDraft.Comment(path: path, line: line, body: body, startLine: start)
}

private let reviewURL = "https://github.com/acme/orbit.api/pull/12"

private func reviewDraft(verdict: ReviewDraft.Verdict = .approve, summary: String = "Looks right.", comments: [ReviewDraft.Comment] = []) -> ReviewDraft {
    ReviewDraft(pr: reviewURL, sha: "0123456", verdict: verdict, summary: summary, comments: comments)
}

let reviewAnchorTests: [(name: String, run: () throws -> Void)] = [
    ("review anchors: the new-side lines of each hunk come from its header, and a hunk that only deletes has none", {
        check(ReviewAnchors.newSideRanges(patch: patch) == [10...14, 58...59], "\(ReviewAnchors.newSideRanges(patch: patch))")
        check(ReviewAnchors.newSideRanges(patch: "@@ -1 +1 @@\n-a\n+b") == [1...1], "a header without counts is one line")
        check(ReviewAnchors.newSideRanges(patch: "").isEmpty, "no patch, no ranges")
    }),

    ("review anchors: a comment inside a hunk stays, one outside it or in a file the pull request does not change moves to the summary", {
        let plan = ReviewAnchors.plan([comment("sync.py", 12), comment("sync.py", 30), comment("elsewhere.py", 1)], files: files)
        check(plan.anchored == [comment("sync.py", 12)], "inside: \(plan.anchored)")
        check(plan.moved.map(\.comment.path) == ["sync.py", "elsewhere.py"], "outside and not in the pull request")
        check(plan.moved[0].reason.contains("outside the changed hunks") && plan.moved[1].reason.contains("not changed by this pull request"), "\(plan.moved.map(\.reason))")
    }),

    ("review anchors: a deleted line is not on the right side, and a file that was removed cannot take a comment", {
        check(ReviewAnchors.plan([comment("sync.py", 41)], files: files).moved.count == 1, "the hunk that only deletes has no new-side line")
        check(ReviewAnchors.plan([comment("old.py", 1)], files: files).moved.first?.reason == "old.py is deleted", "a removed file")
    }),

    ("review anchors: a renamed file takes the comment under its new name, and a file with no patch is let through", {
        let plan = ReviewAnchors.plan([comment("api.py", 2), comment("moved/api.py", 1), comment("big.sql", 5000)], files: files)
        check(plan.anchored.map(\.path) == ["moved/api.py", "moved/api.py", "big.sql"], "\(plan.anchored.map(\.path))")
        check(plan.moved.isEmpty, "nothing moved")
    }),

    ("review anchors: a range stays a range inside one hunk and becomes a single line when its start is not there", {
        let inside = ReviewAnchors.plan([comment("sync.py", 14, start: 11)], files: files).anchored
        check(inside.first?.startLine == 11 && inside.first?.line == 14, "inside one hunk: \(inside)")
        let across = ReviewAnchors.plan([comment("sync.py", 58, start: 12)], files: files).anchored
        check(across.first?.line == 58 && across.first?.startLine == nil, "the start is in another hunk: \(across)")
        check(ReviewAnchors.plan([comment("sync.py", 20, start: 12)], files: files).moved.count == 1, "the end is outside")
        let payload = GitHubActions.reviewPayload(draftRequest(inline: inside))
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let first = (object?["comments"] as? [[String: Any]])?.first
        check(first?["start_line"] as? Int == 11 && first?["start_side"] as? String == "RIGHT" && first?["line"] as? Int == 14, "\(String(describing: first))")
    }),

    ("review anchors: what could not be placed is written under the summary, so nothing the agent wrote is lost", {
        let moved = ReviewAnchors.plan([comment("sync.py", 30, "[AI] Order by id."), comment("elsewhere.py", 3, "[AI] Name it.")], files: files).moved
        let body = ReviewAnchors.foldedBody("[AI] Two things.", moved: moved)
        check(body.hasPrefix("[AI] Two things.\n\nAlso, on lines GitHub would not take a comment on:\n- `sync.py:30`: Order by id.\n- `elsewhere.py:3`: Name it."), body)
        check(ReviewAnchors.foldedBody("", moved: moved).hasPrefix("[AI]\n\nAlso"), "an empty summary still starts with the tag")
        check(ReviewAnchors.foldedBody("[AI] Fine.", moved: []) == "[AI] Fine.", "nothing moved, nothing added")
        check(ReviewAnchors.movedText(1) == "1 comment was put in the summary: GitHub would not place it on a line", "\(String(describing: ReviewAnchors.movedText(1)))")
        check(ReviewAnchors.movedText(3)?.hasPrefix("3 comments were put") == true && ReviewAnchors.movedText(0) == nil, "plural and none")
    }),

    ("review anchors: a draft's request carries the placed comments, the summary with the moved ones, and a pointer only when comments remain", {
        let review = reviewDraft(verdict: .requestChanges, summary: "Two things.", comments: [comment("sync.py", 12), comment("sync.py", 30)])
        let plan = ReviewAnchors.plan(review.comments, files: files)
        let pr = GitHubPR(url: reviewURL, number: 12, title: "ACME-1: Fix it", repo: "acme/orbit.api", updated: Date())
        let request = review.request(.requestChanges, pr: pr, commit: "0123456", actor: "niklas", via: "chat", plan: plan)
        check(request.inline.map(\.line) == [12], "only the placed comment goes on a line")
        check(request.comment.contains("`sync.py:30`") && request.comment.hasPrefix("[AI] Two things."), request.comment)
        let allMoved = reviewDraft(verdict: .comment, summary: "", comments: [comment("elsewhere.py", 3)])
        let bare = allMoved.request(.postComments, pr: pr, commit: nil, actor: nil, via: nil, plan: ReviewAnchors.plan(allMoved.comments, files: files))
        check(bare.inline.isEmpty && bare.comment.contains("`elsewhere.py:3`"), "all moved: \(bare.comment)")
        let none = reviewDraft(verdict: .comment, summary: "", comments: [comment("sync.py", 12)])
        check(none.request(.postComments, pr: pr, commit: nil, actor: nil, via: nil, plan: ReviewAnchors.plan(none.comments, files: files)).comment == "[AI] See the comments on the lines.",
              "a pointer when comments remain on lines")
        check(review.request(.approve, pr: pr, commit: nil, actor: nil, via: nil, plan: plan).inline.isEmpty, "an approval carries no line comments")
    }),

    ("review retry: a review GitHub refuses with 422 is tried once with every line comment in its body, and nothing else is retried", {
        let review = reviewDraft(verdict: .requestChanges, summary: "Two things.", comments: [comment("sync.py", 12, "[AI] Order by id.")])
        let pr = GitHubPR(url: reviewURL, number: 12, title: "ACME-1: Fix it", repo: "acme/orbit.api", updated: Date())
        let request = review.request(.requestChanges, pr: pr, commit: "0123456", actor: nil, via: nil)
        let folded = request.foldingInline()
        check(folded.inline.isEmpty && folded.comment.contains("`sync.py:12`: Order by id.") && folded.comment.hasPrefix("[AI] Two things."), folded.comment)
        check(GitHubActions.arguments(folded)[0] == "pr", "without line comments it is a plain review again")
        let error = GitHubActionError.classify("gh: Unprocessable Entity (HTTP 422)", body: "{\"message\":\"Unprocessable Entity\",\"errors\":[\"Pull request review thread line must be part of the diff\"]}")
        check(error.isUnprocessable && error.message.contains("must be part of the diff") && error.message.contains("Unprocessable Entity"), error.message)
        check(!GitHubActionError.classify("gh: Not Found (HTTP 404)").isUnprocessable && !GitHubActionError.rateLimited.isUnprocessable, "other errors are not retried")
        check(GitHubActionError.classify("gh: Validation Failed (HTTP 422)").isUnprocessable, "validation failed is a 422 too")
    }),

    ("review retry: GitHub's error body is read whether its errors are text or objects", {
        let text = GitHubActionError.detail(fromBody: "{\"message\":\"Validation Failed\",\"errors\":[\"Line must be part of the diff\"]}")
        check(text == "Validation Failed: Line must be part of the diff", "\(String(describing: text))")
        let objects = GitHubActionError.detail(fromBody: "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Review\",\"field\":\"path\",\"code\":\"invalid\"},{\"message\":\"No such file\"}]}")
        check(objects == "Validation Failed: path invalid: No such file", "\(String(describing: objects))")
        check(GitHubActionError.detail(fromBody: "not json") == nil && GitHubActionError.detail(fromBody: "") == nil, "no body, no detail")
        check(GitHubActionError.classify("gh: Unprocessable Entity (HTTP 422)").message == "GitHub would not accept this: gh: Unprocessable Entity (HTTP 422)", "without a body the first line is shown")
    }),

    ("review labels: a line is written in plain digits whatever the language, and a number the agent grouped is still read", {
        check(comment("validators.py", 1290).label == "validators.py:1290", comment("validators.py", 1290).label)
        check(comment("a.py", 14, start: 11).label == "a.py:11-14", "a range")
        check(ReviewDrafts.integer("1 290") == 1290 && ReviewDrafts.integer("1\u{00A0}290") == 1290 && ReviewDrafts.integer("1,290") == 1290 && ReviewDrafts.integer("12") == 12, "grouped digits")
        let parsed = ReviewDrafts.parse(block: "{\"pr\": \"\(reviewURL)\", \"verdict\": \"comment\", \"comments\": [{\"file\": \"v.py\", \"line\": \"1\u{00A0}290\", \"start_line\": 1288, \"body\": \"x\"}]}")
        check(parsed?.comments.first?.line == 1290 && parsed?.comments.first?.startLine == 1288, "\(String(describing: parsed?.comments))")
        let wrong = ReviewDrafts.parse(block: "{\"pr\": \"\(reviewURL)\", \"verdict\": \"comment\", \"comments\": [{\"file\": \"v.py\", \"line\": 5, \"start_line\": 9, \"body\": \"x\"}]}")
        check(wrong?.comments.first?.startLine == nil, "a start after the end is dropped")
    }),

    ("review refusals: every refusal leaves a way on, and 'when green' is offered only while checks are the one thing running", {
        let review = reviewDraft(summary: "Fine.")
        let running = [ReviewApproval.checksRunning]
        check(ReviewApproval.choices(for: .approve, draft: review, reasons: running) == [.approveWhenGreen, .approveAnyway, .commentInstead, .openSheet], "running")
        check(ReviewApproval.choices(for: .approve, draft: review, reasons: [GitHubActions.checksFailing]) == [.approveAnyway, .commentInstead, .openSheet], "failing")
        check(ReviewApproval.choices(for: .approve, draft: review, reasons: [GitHubActions.checksFailing, ReviewApproval.checksRunning]) == [.approveAnyway, .commentInstead, .openSheet], "both")
        let moved = ["The pull request changed after the review: it covered 0123456, the branch is now at abcdef1."]
        check(ReviewApproval.choices(for: .approve, draft: review, reasons: moved) == [.openSheet], "a moved commit is only for the confirmation")
        check(ReviewApproval.choices(for: .approve, draft: review, reasons: [GitHubActions.oneClickOffText]) == [.openSheet], "one click off is only for the confirmation")
        check(ReviewApproval.choices(for: .requestChanges, draft: review, reasons: running) == [.openSheet], "a request for changes is not overridden")
        let empty = reviewDraft(summary: "")
        check(!ReviewApproval.choices(for: .approve, draft: empty, reasons: running).contains(.commentInstead), "nothing to comment")
        check(ReviewApproval.canOverride(running) && !ReviewApproval.canOverride(running + moved) && !ReviewApproval.canOverride([]), "overriding needs every reason to be about the checks")
        for choice in [ReviewChoice.approveAnyway, .approveWhenGreen, .commentInstead, .openSheet] { check(!choice.title.isEmpty, "a title") }
    }),
]

private func draftRequest(inline: [ReviewDraft.Comment]) -> GitHubActionRequest {
    var request = GitHubActionRequest(.requestChanges, repo: "acme/orbit.api", number: 12, title: "ACME-1: Fix it", url: reviewURL, comment: "[AI] x")
    request.inline = inline
    return request
}
