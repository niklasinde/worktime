import Foundation

/// What the Jira page's detail pane shows for the selected ticket, apart from the views.
enum JiraDetail {
    enum State: Equatable {
        case loading
        case loaded(JiraIssue)
        case failed(JiraError)
    }

    struct Fact: Equatable {
        let title: String
        let value: String
    }

    enum Block: Equatable {
        case paragraph(String)
        case bullet(String)
    }

    /// A fetched issue is shown as it is for this long before the next selection fetches it again.
    static let freshFor: TimeInterval = 300
    static let shownComments = 5

    static func needsFetch(fetchedAt: Date?, now: Date, force: Bool = false) -> Bool {
        guard let fetchedAt, !force else { return true }
        return now.timeIntervalSince(fetchedAt) >= freshFor
    }

    /// The key a step of `offset` from `current` lands on; the first or last one when nothing is selected, and never past either end.
    static func step(from current: String?, offset: Int, in keys: [String]) -> String? {
        guard !keys.isEmpty else { return nil }
        let index = current.flatMap { keys.firstIndex(of: $0) }
        return keys[index.map { min(max($0 + offset, 0), keys.count - 1) } ?? (offset > 0 ? 0 : keys.count - 1)]
    }

    static func facts(_ issue: JiraIssue, now: Date) -> [Fact] {
        let rows: [(String, String?)] = [
            ("Assignee", issue.assignee ?? "Unassigned"),
            ("Reporter", issue.reporter),
            ("Created", issue.created.map { GitHubLogic.updatedText($0, now: now) }),
            ("Updated", issue.updated.map { GitHubLogic.updatedText($0, now: now) }),
            ("Labels", issue.labels.isEmpty ? nil : issue.labels.joined(separator: ", ")),
            ("Fix version", issue.fixVersions.isEmpty ? nil : issue.fixVersions.joined(separator: ", ")),
            ("Logged", issue.timeSpentSeconds.map(JiraWorklog.format)),
        ]
        return rows.compactMap { title, value in value.map { Fact(title: title, value: $0) } }
    }

    /// The description as paragraphs and bullet items, one per non-empty line of its plain text.
    static func blocks(_ description: String) -> [Block] {
        description.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(" |") { text.removeLast(2) }
            if text.hasPrefix("- ") { return .bullet(String(text.dropFirst(2))) }
            return text.isEmpty ? nil : .paragraph(text)
        }
    }

    /// The newest comments, oldest first, and how many earlier ones stay in Jira.
    static func recentComments(_ issue: JiraIssue) -> (shown: [JiraIssue.Comment], hidden: Int) {
        let shown = Array(issue.comments.suffix(shownComments))
        return (shown, max(issue.commentTotal - shown.count, 0))
    }
}
