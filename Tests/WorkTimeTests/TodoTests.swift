import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_793_700_000)

let todoTests: [(name: String, run: () throws -> Void)] = [
    ("a reminder's text is trimmed and an empty one is not added", {
        check(TodoLogic.text("  Buy milk \n") == "Buy milk", "trimmed")
        check(TodoLogic.text("   ") == nil, "blank")
    }),

    ("meeting action items reach back 14 days", {
        check(TodoLogic.meetingCutoff(now: now) == now.addingTimeInterval(-14 * 24 * 3600), "cutoff")
    }),

    ("meeting todos are the unchecked action items of recent meetings, and checking one hides it", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("todo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let summary = ParsedSummary(MeetingSummary(title: "Standup", actionItems: [.init(task: "Send the report", owner: "Anna"), .init(task: "Book a room", owner: nil)],
                                                   topics: []))
        try store.saveSummary("Meeting-2026-10-28-0900.m4a", summary)
        try store.saveSummary("Meeting-2026-09-01-0900.m4a", summary)
        let since = TodoLogic.meetingCutoff(now: ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!)
        let items = try store.openActionItems(limit: 100, since: since)
        check(items.map(\.task) == ["Send the report", "Book a room"], "recent only \(items.map(\.task))")
        check(items.first?.owner == "Anna", "owner")
        try store.setChecked(actionItem: items[0].id, true)
        check(try store.openActionItems(limit: 100, since: since).map(\.task) == ["Book a room"], "checked one is gone")
        check(try store.schemaVersion() == MeetingStore.migrations.count, "the todos table is created and dropped again")
    }),

    ("a meeting action item stays a suggestion until it is approved or dismissed", {
        let items = [item(1, "Send the report"), item(2, "Book a room"), item(3, "Call Anna")]
        var decisions = SuggestionDecisions()
        check(SuggestionLogic.suggestions(items, decisions: decisions).map(\.id) == [1, 2, 3], "all open at first")
        decisions.approved.insert(1)
        decisions.dismissed.insert(3)
        check(SuggestionLogic.suggestions(items, decisions: decisions).map(\.id) == [2], "answered ones leave")
        check(decisions.decided(1) && decisions.decided(3) && !decisions.decided(2), "decided")
    }),

    ("approving makes a reminder that links to the meeting, with the owner in the notes", {
        let reminder = SuggestionLogic.reminder(from: item(7, "Send the report", meeting: 42, owner: "Anna"), now: now)
        check(reminder.title == "Send the report", "title")
        check(reminder.source == .meeting(id: 42, title: "Weekly sync"), "source \(String(describing: reminder.source))")
        check(reminder.notes == "Owner: Anna", "notes \(String(describing: reminder.notes))")
        check(reminder.due == nil && reminder.isOpen, "open and undated")
        let due = ReminderDue(date: now.addingTimeInterval(3600))
        check(SuggestionLogic.reminder(from: item(8, "x"), due: due, now: now).due == due, "due")
        check(SuggestionLogic.reminder(from: item(9, "x"), now: now).notes == nil, "no owner, no notes")
    }),

    ("approved and dismissed items are remembered across a restart", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("suggestions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(SuggestionDecisions.fileName)
        check(SuggestionDecisions.load(from: file) == SuggestionDecisions(), "a missing file is no decisions")
        let decisions = SuggestionDecisions(approved: [1, 2], dismissed: [3])
        try decisions.save(to: file)
        check(SuggestionDecisions.load(from: file) == decisions, "round trip")
        try Data("not json".utf8).write(to: file)
        check(SuggestionDecisions.load(from: file) == SuggestionDecisions(), "an unreadable file is no decisions")
    }),

    ("a suggestion is not an agent's reminder until it is approved", {
        let source = NoticeSource(agent: "assistant:work:reviewer", workspace: "work")
        let list = ReminderRequest(id: "a", action: .list, source: source, created: now)
        var book = ReminderBook()
        check(ReminderLogic.handle(list, book: book, addedBy: "Reviewer", jiraSite: nil, now: now).reply.message == "No open reminders.\n",
              "a suggested item is not in the book")
        book.add(SuggestionLogic.reminder(from: item(7, "Send the report", meeting: 42), now: now))
        let message = ReminderLogic.handle(list, book: book, addedBy: "Reviewer", jiraSite: nil, now: now).reply.message
        check(message.contains("Send the report") && message.contains("meeting 42"), "the approved one is listed with its source: \(message)")
    }),

    ("the page filter looks in the title, notes and source and keeps one kind of source", {
        let pull = ReminderSource.pullRequest(GitHubLink.Target(repo: "acme/api", number: 7))
        let reminders = [
            Reminder(id: "a", title: "Review the rule engine", created: now, source: pull),
            Reminder(id: "b", title: "Send the report", notes: "Owner: Anna", created: now, source: .meeting(id: 1, title: "Weekly sync")),
            Reminder(id: "c", title: "Book the dentist", created: now),
        ]
        func ids(_ filter: ReminderPageFilter) -> [String] { reminders.filter(filter.matches).map(\.id) }
        check(ids(ReminderPageFilter()) == ["a", "b", "c"], "empty keeps all")
        check(ids(ReminderPageFilter(query: "REPORT")) == ["b"], "title, any case")
        check(ids(ReminderPageFilter(query: "anna")) == ["b"], "notes")
        check(ids(ReminderPageFilter(query: "acme")) == ["a"], "source")
        check(ids(ReminderPageFilter(query: "the report")) == ["b"], "all words")
        check(ids(ReminderPageFilter(kind: .githubPR)) == ["a"], "kind")
        check(ids(ReminderPageFilter(query: "dentist", kind: .meeting)).isEmpty, "query and kind together")
        check(ReminderPageFilter(kind: .meeting).matches(item(1, "x")) && !ReminderPageFilter(kind: .jira).matches(item(1, "x")), "suggestions are meetings")
        check(ReminderPageFilter(query: "room").matches(item(2, "Book a room")) && !ReminderPageFilter(query: "room").matches(item(3, "Call")), "suggestion text")
    }),

    ("revealing a reminder keeps a filter that shows it and drops one that hides it", {
        let dentist = Reminder(id: "c", title: "Book the dentist", created: now)
        let filter = ReminderPageFilter(query: "dentist")
        check(filter.revealing(dentist) == filter, "kept when it matches")
        check(ReminderPageFilter(query: "report").revealing(dentist).isEmpty, "dropped when it hides it")
        check(ReminderPageFilter(kind: .jira).revealing(item(1, "x")).isEmpty, "dropped for a suggestion too")
        check(SuggestionLogic.focusID(item(5, "x")) == "suggestion:5", "a suggestion's focus id")
    }),

    ("the page lists completed reminders latest first and offers the source kinds that exist", {
        var done1 = Reminder(id: "1", title: "a", created: now)
        done1.completed = now
        var done2 = Reminder(id: "2", title: "b", created: now)
        done2.completed = now.addingTimeInterval(60)
        let open = Reminder(id: "3", title: "c", created: now, source: .jira(key: "ACME-1"))
        check(SuggestionLogic.completed([done1, open, done2]).map(\.id) == ["2", "1"], "latest first, open ones left out")
        check(SuggestionLogic.kinds(in: [open], suggested: []) == [.jira], "jira only")
        check(SuggestionLogic.kinds(in: [open], suggested: [item(1, "x")]) == [.jira, .meeting], "meetings once something is suggested")
    }),

    ("resolved keeps dismissed suggestions and completed reminders until they are restored or cleared", {
        let items = [item(1, "a"), item(2, "b"), item(3, "c")]
        var decisions = SuggestionDecisions(approved: [1], dismissed: [2, 3])
        check(SuggestionLogic.dismissed(items, decisions: decisions).map(\.id) == [2, 3], "only the dismissed ones")
        decisions.restore(2)
        check(SuggestionLogic.suggestions(items, decisions: decisions).map(\.id) == [2], "a restored one is a suggestion again")
        check(SuggestionLogic.dismissed(items, decisions: decisions).map(\.id) == [3], "and leaves Resolved")
        var book = ReminderBook()
        let done = book.add(Reminder(id: "", title: "done", created: now))
        let open = book.add(Reminder(id: "", title: "open", created: now))
        book.complete(done.id, now: now)
        book.clearCompleted()
        check(book.reminders.map(\.id) == [open.id], "clear deletes only the completed ones")
    }),

    ("a date picker's choice is a day for an all-day reminder and the time otherwise", {
        let stockholm = TimeZone(identifier: "Europe/Stockholm")!
        let afternoon = ISO8601DateFormatter().date(from: "2026-11-12T14:30:00Z")!
        let day = ReminderLogic.due(afternoon, allDay: true, timeZone: stockholm)
        check(day.allDay && day.date == ISO8601DateFormatter().date(from: "2026-11-11T23:00:00Z")!, "start of the day \(day.date)")
        let timed = ReminderLogic.due(afternoon, allDay: false, timeZone: stockholm)
        check(!timed.allDay && timed.date == afternoon, "the time is kept")
    }),
]

private func item(_ id: Int64, _ task: String, meeting: Int64 = 1, owner: String? = nil) -> MeetingTodo {
    MeetingTodo(id: id, meeting: meeting, date: now, title: "Weekly sync", owner: owner, task: task)
}
