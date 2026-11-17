import Foundation

/// One file of a pull request as GitHub lists it: where it is now, where it was, and its patch (missing for a file too large to show).
struct DiffFile: Equatable, Sendable {
    var path: String
    var previousPath: String?
    var patch: String?
    var status: String?
}

/// Which of a drafted review's comments GitHub will take on a line. GitHub answers 422 for the whole review when one comment names a
/// file the pull request does not change or a line outside its hunks, so each comment is checked first and the rest go into the summary.
enum ReviewAnchors {
    struct Moved: Equatable, Sendable {
        let comment: ReviewDraft.Comment
        let reason: String
    }

    struct Plan: Equatable, Sendable {
        var anchored: [ReviewDraft.Comment] = []
        var moved: [Moved] = []
    }

    /// The new-side line numbers each hunk of a patch shows, as `@@ -a,b +c,d @@` says: context and added lines are all there.
    static func newSideRanges(patch: String) -> [ClosedRange<Int>] {
        patch.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> ClosedRange<Int>? in
            guard line.hasPrefix("@@"), let plus = line.firstIndex(of: "+") else { return nil }
            let numbers = line[line.index(after: plus)...].prefix { $0.isNumber || $0 == "," }.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
            let count = numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1
            return count > 0 ? start...(start + count - 1) : nil
        }
    }

    /// The files of a pull request from one page of `pulls/{n}/files`.
    static func parseFiles(_ data: Data) -> [DiffFile]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let path = row["filename"] as? String else { return nil }
            return DiffFile(path: path, previousPath: row["previous_filename"] as? String, patch: row["patch"] as? String, status: row["status"] as? String)
        }
    }

    static func plan(_ comments: [ReviewDraft.Comment], files: [DiffFile]) -> Plan {
        var plan = Plan()
        for comment in comments {
            switch anchor(comment, files: files) {
            case .success(let placed): plan.anchored.append(placed)
            case .failure(let reason): plan.moved.append(Moved(comment: comment, reason: reason.text))
            }
        }
        return plan
    }

    private struct Reason: Error { let text: String }

    private static func anchor(_ comment: ReviewDraft.Comment, files: [DiffFile]) -> Result<ReviewDraft.Comment, Reason> {
        guard let file = files.first(where: { $0.path == comment.path }) ?? files.first(where: { $0.previousPath == comment.path }) else {
            return .failure(Reason(text: "\(comment.path) is not changed by this pull request"))
        }
        var placed = comment
        placed.path = file.path
        if file.status == "removed" { return .failure(Reason(text: "\(file.path) is deleted")) }
        guard let patch = file.patch else { return .success(placed) }
        let ranges = newSideRanges(patch: patch)
        guard let hunk = ranges.first(where: { $0.contains(comment.line) }) else {
            return .failure(Reason(text: "line \(comment.line) of \(file.path) is outside the changed hunks"))
        }
        if let start = comment.startLine, !(start < comment.line && hunk.contains(start)) { placed.startLine = nil }
        return .success(placed)
    }

    /// The summary with the comments that could not go on a line added under it, so nothing the agent wrote is lost.
    static func foldedBody(_ summary: String, moved: [Moved]) -> String {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moved.isEmpty else { return text }
        let list = moved.map { "- `\($0.comment.label)`: \(ReviewDraft.untagged($0.comment.body))" }.joined(separator: "\n")
        let heading = "Also, on lines GitHub would not take a comment on:"
        return [text.isEmpty ? ReviewDrafts.tag : text, heading + "\n" + list].joined(separator: "\n\n")
    }

    /// How many comments are told to be in the summary: the ones the plan moved and the ones the retry moved.
    static func movedText(_ count: Int) -> String? {
        count > 0 ? "\(count) comment\(count == 1 ? " was" : "s were") put in the summary: GitHub would not place \(count == 1 ? "it" : "them") on a line" : nil
    }
}

extension ReviewDraft.Comment {
    /// `path:line` or `path:start-line`, with plain digits whatever the language of the Mac.
    var label: String { path + ":" + (startLine.map { "\($0)-" } ?? "") + String(line) }
}

extension ReviewDraft {
    static func untagged(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(ReviewDrafts.tag) else { return text }
        return String(text.dropFirst(ReviewDrafts.tag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension GitHubClient {
    /// The files of a pull request with their patches, 100 a page, or nil when GitHub could not be asked. Reads only.
    nonisolated static func fetchPullFiles(cli: URL?, repo: String, number: Int) -> [DiffFile]? {
        guard let cli else { return nil }
        var files: [DiffFile] = []
        for page in 1...30 {
            guard let output = run(cli, ["api", "repos/\(repo)/pulls/\(number)/files?per_page=100&page=\(page)"]), output.status == 0,
                  let found = ReviewAnchors.parseFiles(output.stdout) else { return nil }
            files += found
            if found.count < 100 { return files }
        }
        return files
    }
}

/// What a refused click leaves to do: every refusal names a way on that the user can click.
enum ReviewChoice: Hashable, Sendable {
    case approveAnyway, approveWhenGreen, commentInstead, openSheet

    var title: String {
        switch self {
        case .approveAnyway: return "Approve anyway"
        case .approveWhenGreen: return "Approve when green"
        case .commentInstead: return "Comment instead"
        case .openSheet: return "Review in the confirmation"
        }
    }
}

/// Why a click did not post and what can be clicked instead, kept with the card.
struct ReviewRefusal: Equatable, Sendable {
    var action: ReviewAction
    var reasons: [String]
    var choices: [ReviewChoice]

    var text: String { reasons.joined(separator: " ") }
}

extension ReviewApproval {
    static let checksRunning = GitHubActions.checksRunning
    static let overridable: Set<String> = [checksRunning, GitHubActions.checksFailing, "This pull request is a draft.", "Changes were requested in an earlier review"]

    /// Whether the user's own click can go ahead of these reasons: they are about the pull request's checks and state, not about the
    /// commit having moved or the setting being off.
    static func canOverride(_ reasons: [String]) -> Bool { !reasons.isEmpty && reasons.allSatisfy(overridable.contains) }

    /// What the card offers after the click was not enough. The confirmation is always there; the others only when they make sense.
    static func choices(for action: ReviewAction, draft: ReviewDraft, reasons: [String]) -> [ReviewChoice] {
        var choices: [ReviewChoice] = []
        if action == .approve, canOverride(reasons) {
            if reasons == [checksRunning] { choices.append(.approveWhenGreen) }
            choices.append(.approveAnyway)
            if draft.problem(for: .postComments) == nil { choices.append(.commentInstead) }
        }
        return choices + [.openSheet]
    }
}

enum ReviewPostMode: Equatable, Sendable {
    case normal
    /// The user clicked "Approve anyway": the reasons about checks and state no longer hold the click back.
    case anyway
    /// The user asked for the confirmation, whatever the route.
    case sheet
}
