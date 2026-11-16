import Foundation

/// What `add_reminder` asks for; `link` is classified into a source when the app takes it.
struct ReminderDraft: Codable, Equatable, Sendable {
    var title: String
    var notes: String?
    var due: ReminderDue?
    var link: String?
    var priority = ReminderPriority.none
}

/// What the `--mcp` process hands the app through the agent inbox; the app answers with a `NoticeReply`.
struct ReminderRequest: Codable, Equatable {
    enum Action: String, Codable { case add, list, complete }

    var id: String
    var action: Action
    var draft: ReminderDraft?
    var dueBefore: Date?
    var dueAfter: Date?
    var priority: ReminderPriority?
    var query: String?
    var sourceKind: String?
    var sourceQuery: String?
    var reminder: String?
    var source: NoticeSource
    var created: Date

    var filter: ReminderFilter {
        ReminderFilter(dueBefore: dueBefore, dueAfter: dueAfter, priority: priority, query: query, sourceKind: sourceKind, sourceQuery: sourceQuery)
    }
}

/// An Apple Reminders reminder as the one-time import reads it.
struct ImportedReminder: Equatable {
    var title: String
    var notes: String?
    var url: String?
    var due: ReminderDue?
    var priority = ReminderPriority.none
    var created: Date?
}

enum ReminderSection: Int, CaseIterable {
    case overdue, today, upcoming, anytime

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "No date"
        }
    }
}

/// The times the "remind me" menus offer.
enum ReminderPreset: CaseIterable {
    case today, inAnHour, tomorrow, nextWeek, noDate

    var title: String {
        switch self {
        case .today: "Today"
        case .inAnHour: "In an hour"
        case .tomorrow: "Tomorrow morning"
        case .nextWeek: "Next week"
        case .noDate: "No date"
        }
    }
}

enum ReminderLogic {
    static let listLimit = 100
    static let morningHour = 9
    static let userInfoKey = "reminder"

    static func requestName(_ id: String) -> String { "\(id).reminder.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".reminder.json") }

    static func alarmIdentifier(_ id: String) -> String { "reminder-" + id }

    // MARK: Arguments

    static func draft(_ args: [String: Any], now: Date, timeZone: TimeZone = .current) -> Result<ReminderDraft, NoticeError> {
        func text(_ name: String) -> String? { FilterLogic.text(args, name) }
        guard let title = text("title") else { return .failure(NoticeError("title is required.")) }
        guard title.count <= NoticeLogic.titleLimit else {
            return .failure(NoticeError("title is \(title.count) characters; keep it under \(NoticeLogic.titleLimit)."))
        }
        let notes = text("notes")
        if let notes, notes.count > NoticeLogic.bodyLimit {
            return .failure(NoticeError("notes is \(notes.count) characters; the limit is \(NoticeLogic.bodyLimit)."))
        }
        let link = text("link")
        if let link, ReminderSource.parse(link) == nil {
            return .failure(NoticeError("link must be a GitHub pull request (url or owner/repo#number), a Jira key or url, a Slack message link, "
                                        + "meeting:<id> or another https url, not \(link)."))
        }
        var priority = ReminderPriority.none
        if let raw = text("priority") {
            guard let parsed = ReminderPriority(rawValue: raw.lowercased()) else { return .failure(NoticeError("priority must be none, low, medium or high.")) }
            priority = parsed
        }
        var due: ReminderDue?
        if let raw = text("due") {
            switch self.due(raw, now: now, timeZone: timeZone) {
            case .success(let parsed): due = parsed
            case .failure(let error): return .failure(error)
            }
        }
        return .success(ReminderDraft(title: title, notes: notes, due: due, link: link, priority: priority))
    }

    /// `due` as notify reads `at`, or a date alone (`2026-11-13`) for an all-day reminder, from today up to 30 days ahead.
    static func due(_ text: String, now: Date, timeZone: TimeZone = .current) -> Result<ReminderDue, NoticeError> {
        guard let day = day(text, timeZone: timeZone) else {
            return NoticeLogic.time(text, now: now, timeZone: timeZone, name: "due").map { ReminderDue(date: $0) }
        }
        guard day >= calendar(timeZone).startOfDay(for: now) else { return .failure(NoticeError("due \(text) is in the past.")) }
        guard day.timeIntervalSince(now) <= NoticeLogic.maxAhead else { return .failure(NoticeError("due \(text) is more than 30 days away.")) }
        return .success(ReminderDue(date: day, allDay: true))
    }

    /// `due_before` as a date: a day counts in full, otherwise as notify reads `at`, past or not.
    static func dueBefore(_ text: String, now: Date, timeZone: TimeZone = .current) -> Result<Date, NoticeError> {
        FilterLogic.bound(text, name: "due_before", end: true, now: now, timeZone: timeZone)
    }

    static func dayText(_ date: Date, timeZone: TimeZone = .current) -> String {
        dueText(ReminderDue(date: date, allDay: true), timeZone: timeZone)
    }

    static func day(_ text: String, timeZone: TimeZone) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The due date a menu choice means.
    static func due(_ preset: ReminderPreset, now: Date, timeZone: TimeZone = .current) -> ReminderDue? {
        let calendar = calendar(timeZone)
        let today = calendar.startOfDay(for: now)
        func morning(of day: Date) -> ReminderDue? {
            calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day).map { ReminderDue(date: $0) }
        }
        switch preset {
        case .today: return ReminderDue(date: today, allDay: true)
        case .inAnHour: return ReminderDue(date: Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.up) * 60 + 3600))
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: today).flatMap(morning)
        case .nextWeek:
            let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
            return calendar.date(byAdding: .day, value: 7 - sinceMonday, to: today).flatMap(morning)
        case .noDate: return nil
        }
    }

    // MARK: Order, sections and labels

    /// Those with a due date first, soonest first, then the rest by when they were made.
    static func ordered(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted {
            switch ($0.due?.date, $1.due?.date) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.created < $1.created
            }
        }
    }

    static func section(of reminder: Reminder, now: Date, timeZone: TimeZone = .current) -> ReminderSection {
        guard let due = reminder.due else { return .anytime }
        let calendar = calendar(timeZone)
        if calendar.isDate(due.date, inSameDayAs: now) { return due.allDay || due.date >= now ? .today : .overdue }
        return due.date < now ? .overdue : .upcoming
    }

    /// The non-empty sections in display order, each in `ordered` order.
    static func sections(_ reminders: [Reminder], now: Date, timeZone: TimeZone = .current) -> [(section: ReminderSection, reminders: [Reminder])] {
        let ordered = ordered(reminders)
        return ReminderSection.allCases.compactMap { section in
            let inSection = ordered.filter { self.section(of: $0, now: now, timeZone: timeZone) == section }
            return inSection.isEmpty ? nil : (section, inSection)
        }
    }

    /// "Today 14:00", "Tomorrow", "12 Nov" or "12 Nov 09:00", for the list.
    static func dueLabel(_ due: ReminderDue, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let calendar = calendar(timeZone)
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        var day: String
        if calendar.isDate(due.date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due.date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            day = formatter.string(from: due.date)
        }
        if !due.allDay { day += " " + time.string(from: due.date) }
        return day
    }

    /// When the system should notify: the due time of an open reminder with a time that has not come yet.
    static func alarm(for reminder: Reminder, now: Date) -> Date? {
        guard reminder.isOpen, let due = reminder.due, !due.allDay, due.date > now else { return nil }
        return due.date
    }

    // MARK: Duplicates and the import

    /// An open reminder with the same title (any case) and the same due day or minute.
    static func duplicate(of title: String, due: ReminderDue?, in existing: [Reminder], timeZone: TimeZone = .current) -> Reminder? {
        existing.first {
            $0.isOpen && $0.title.caseInsensitiveCompare(title) == .orderedSame && sameDue($0.due, due, timeZone: timeZone)
        }
    }

    private static func sameDue(_ a: ReminderDue?, _ b: ReminderDue?, timeZone: TimeZone) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        guard a.allDay == b.allDay else { return false }
        return a.allDay ? calendar(timeZone).isDate(a.date, inSameDayAs: b.date) : abs(a.date.timeIntervalSince(b.date)) < 60
    }

    /// The imported reminders added to the book: the url becomes the source, WorkTime's old "Added by" note line the sender,
    /// and ones the book already has are skipped.
    static func importing(_ items: [ImportedReminder], into book: ReminderBook, now: Date, jiraSite: String? = nil,
                          timeZone: TimeZone = .current) -> ReminderBook {
        var book = book
        for item in items {
            guard let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                  duplicate(of: title, due: item.due, in: book.reminders, timeZone: timeZone) == nil else { continue }
            var addedBy: String?
            let notes = (item.notes ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
                if line.hasPrefix("Added by ") {
                    addedBy = String(line.dropFirst("Added by ".count))
                    return false
                }
                return line != item.url
            }.joined(separator: "\n").nilIfEmpty
            book.add(Reminder(id: "", title: title, notes: notes, due: item.due, priority: item.priority, created: item.created ?? now,
                              source: item.url.flatMap { ReminderSource.parse($0, jiraSite: jiraSite) }, addedBy: addedBy))
        }
        return book
    }

    // MARK: The app's side

    /// What the app does with a request, against its book; the new book is returned for the caller to keep.
    static func handle(_ request: ReminderRequest, book: ReminderBook, addedBy: String, jiraSite: String?, now: Date,
                       timeZone: TimeZone = .current) -> (reply: NoticeReply, book: ReminderBook) {
        var book = book
        func reply(_ ok: Bool, _ id: String?, _ message: String) -> (reply: NoticeReply, book: ReminderBook) {
            (NoticeReply(id: request.id, ok: ok, notice: id, message: message), book)
        }
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, nil, "The request is too old.") }
        switch request.action {
        case .add:
            guard let draft = request.draft else { return reply(false, nil, "title is required.") }
            if let same = duplicate(of: draft.title, due: draft.due, in: book.reminders, timeZone: timeZone) {
                return reply(true, same.id, "\"\(same.title)\" is already open, so it was not added again; id \(same.id).")
            }
            let saved = book.add(Reminder(id: "", title: draft.title, notes: draft.notes, due: draft.due, priority: draft.priority, created: now,
                                          source: draft.link.flatMap { ReminderSource.parse($0, jiraSite: jiraSite) }, addedBy: addedBy))
            return reply(true, saved.id, "Added \"\(saved.title)\"" + (saved.due.map { ", due " + dueText($0, timeZone: timeZone) } ?? "")
                         + "; id \(saved.id).")
        case .list:
            let open = open(book.reminders, filter: request.filter)
            guard !open.isEmpty else { return reply(true, nil, "No open reminders.\n") }
            let lines = open.prefix(listLimit).map { line($0, timeZone: timeZone) }
            return reply(true, nil, lines.joined(separator: "\n") + (open.count > listLimit ? "\n\(open.count - listLimit) more not shown." : "") + "\n")
        case .complete:
            guard let id = request.reminder, let reminder = book.reminder(id) else { return reply(false, nil, "No reminder with id \(request.reminder ?? "").") }
            guard reminder.isOpen else { return reply(false, id, "\"\(reminder.title)\" is already completed.") }
            book.complete(id, now: now)
            return reply(true, id, "Completed \"\(reminder.title)\".")
        }
    }

    /// Open reminders matching the filter, due ones soonest first.
    static func open(_ reminders: [Reminder], filter: ReminderFilter) -> [Reminder] {
        ordered(reminders.filter { $0.isOpen && filter.matches($0) })
    }

    static func line(_ reminder: Reminder, timeZone: TimeZone = .current) -> String {
        var parts = ["id \(reminder.id)", reminder.title]
        if let due = reminder.due { parts.append("due " + dueText(due, timeZone: timeZone)) }
        if reminder.priority != .none { parts.append("\(reminder.priority.rawValue) priority") }
        if let source = reminder.source { parts.append("\(source.kind.rawValue) \(source.reference)") }
        if let addedBy = reminder.addedBy { parts.append("added by \(addedBy)") }
        return "- " + parts.joined(separator: " \u{00B7} ")
    }

    static func dueText(_ due: ReminderDue, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = due.allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: due.date)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
