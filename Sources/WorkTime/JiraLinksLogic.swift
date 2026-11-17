import Foundation

struct JiraMeetingLink: Equatable, Identifiable {
    let id: Int64
    let title: String
    let date: Date
}

/// What else WorkTime holds about a ticket: the reminders and Slack messages that name it and the meetings that mention it.
enum JiraLinks {
    static let meetingLimit = 5

    /// Whether the text names the ticket, in any case, and not a longer key that starts the same (`ACME-12` is not in `ACME-123`).
    static func mentions(_ text: String, key: String) -> Bool {
        guard let pattern = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: key) + "(?![0-9])",
                                                     options: .caseInsensitive) else { return false }
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The open reminders that point at the ticket or name it in their title or notes.
    static func reminders(_ key: String, in reminders: [Reminder]) -> [Reminder] {
        ReminderLogic.ordered(reminders.filter { reminder in
            guard reminder.isOpen else { return false }
            if reminder.source?.kind == .jira, reminder.source?.reference.caseInsensitiveCompare(key) == .orderedSame { return true }
            return mentions(reminder.title, key: key) || reminder.notes.map { mentions($0, key: key) } ?? false
        })
    }

    static func slack(_ key: String, in messages: [SlackMessage]) -> [SlackMessage] {
        messages.filter { mentions($0.text, key: key) }.sorted { $0.date > $1.date }
    }

    /// A meeting search hit counts when its snippet, cleared of the search's highlight marks, names the ticket as a whole.
    static func confirms(snippet: String, key: String) -> Bool { mentions(snippet.replacingOccurrences(of: "**", with: ""), key: key) }
}
