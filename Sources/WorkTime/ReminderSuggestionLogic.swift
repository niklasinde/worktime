import Foundation

/// Which meeting action items the user answered: approved ones became reminders, dismissed ones stay hidden. Kept in `reminder-suggestions.json`.
struct SuggestionDecisions: Codable, Equatable, Sendable {
    static let fileName = "reminder-suggestions.json"

    var approved: Set<Int64> = []
    var dismissed: Set<Int64> = []

    func decided(_ item: Int64) -> Bool { approved.contains(item) || dismissed.contains(item) }

    /// Puts a dismissed item back among the suggestions.
    mutating func restore(_ item: Int64) { dismissed.remove(item) }

    static func load(from file: URL) -> SuggestionDecisions {
        (try? Data(contentsOf: file)).flatMap { AgentInbox.decode(SuggestionDecisions.self, from: $0) } ?? SuggestionDecisions()
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentInbox.encode(self).write(to: file, options: .atomic)
    }
}

/// What the Reminders page narrows its lists to: words in the title, notes or source, and one kind of source.
struct ReminderPageFilter: Equatable {
    var query = ""
    var kind: ReminderSource.Kind?

    var isEmpty: Bool { query.isEmpty && kind == nil }

    func matches(_ reminder: Reminder) -> Bool {
        (kind == nil || reminder.source?.kind == kind) && matches(text: [reminder.title, reminder.notes, reminder.source?.label, reminder.addedBy])
    }

    func matches(_ item: MeetingTodo) -> Bool {
        (kind == nil || kind == .meeting) && matches(text: [item.task, item.title, item.owner])
    }

    /// This filter, or none when it would hide the reminder being revealed.
    func revealing(_ reminder: Reminder) -> ReminderPageFilter { matches(reminder) ? self : ReminderPageFilter() }

    func revealing(_ item: MeetingTodo) -> ReminderPageFilter { matches(item) ? self : ReminderPageFilter() }

    private func matches(text parts: [String?]) -> Bool {
        let words = query.split(separator: " ").map(String.init)
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

enum SuggestionLogic {
    /// What the page scrolls to and highlights for a suggestion: its id could be a reminder's too, so it is told apart.
    static func focusID(_ item: MeetingTodo) -> String { "suggestion:\(item.id)" }

    /// The meeting action items nobody answered yet, in the order given.
    static func suggestions(_ items: [MeetingTodo], decisions: SuggestionDecisions) -> [MeetingTodo] {
        items.filter { !decisions.decided($0.id) }
    }

    /// The action items the user dismissed, which Resolved keeps so they can be brought back.
    static func dismissed(_ items: [MeetingTodo], decisions: SuggestionDecisions) -> [MeetingTodo] {
        items.filter { decisions.dismissed.contains($0.id) }
    }

    /// The reminder an approved action item becomes: its task, with the meeting as source and its owner in the notes.
    static func reminder(from item: MeetingTodo, due: ReminderDue? = nil, now: Date) -> Reminder {
        Reminder(id: "", title: String(item.task.prefix(NoticeLogic.titleLimit)), notes: item.owner.map { "Owner: \($0)" }, due: due, created: now,
                 source: .meeting(id: item.meeting, title: item.title))
    }

    /// Completed reminders, the latest completion first.
    static func completed(_ reminders: [Reminder]) -> [Reminder] {
        reminders.filter { !$0.isOpen }.sorted { ($0.completed ?? .distantPast) > ($1.completed ?? .distantPast) }
    }

    /// The source kinds that exist among the reminders and suggestions, in their usual order, for the filter chips.
    static func kinds(in reminders: [Reminder], suggested: [MeetingTodo]) -> [ReminderSource.Kind] {
        var present = Set(reminders.compactMap { $0.source?.kind })
        if !suggested.isEmpty { present.insert(.meeting) }
        return ReminderSource.Kind.allCases.filter(present.contains)
    }
}
