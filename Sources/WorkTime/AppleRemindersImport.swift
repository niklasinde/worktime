import EventKit

/// The user's open Apple Reminders, read once when WorkTime starts keeping its own; nothing in Reminders is changed.
enum AppleRemindersImport {
    static let doneKey = "appleRemindersImported"

    static var allowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    static func incomplete() async -> [ImportedReminder] {
        guard allowed else { return [] }
        let events = EKEventStore()
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(imported))
            }
        }
    }

    private static func imported(_ reminder: EKReminder) -> ImportedReminder {
        let due = reminder.dueDateComponents.flatMap { components in
            (components.date ?? Calendar.current.date(from: components)).map { ReminderDue(date: $0, allDay: components.hour == nil) }
        }
        return ImportedReminder(title: reminder.title ?? "", notes: reminder.notes, url: reminder.url?.absoluteString, due: due,
                                priority: ReminderPriority(eventKit: reminder.priority), created: reminder.creationDate)
    }
}
