import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let stockholm = TimeZone(identifier: "Europe/Stockholm")!
private let now = ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z")!
private let reviewer = NoticeSource(agent: "assistant:work:reviewer", workspace: "work")
private let pullRequest = ReminderSource.pullRequest(GitHubLink.Target(repo: "acme/api", number: 7))

private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func reminder(_ title: String, due: ReminderDue? = nil, created: TimeInterval = 0, source: ReminderSource? = nil) -> Reminder {
    Reminder(id: title, title: title, due: due, created: now.addingTimeInterval(created), source: source)
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private func request(_ action: ReminderRequest.Action, draft: ReminderDraft? = nil, dueBefore: Date? = nil, reminder: String? = nil,
                     created: Date = now) -> ReminderRequest {
    ReminderRequest(id: UUID().uuidString, action: action, draft: draft, dueBefore: dueBefore, reminder: reminder, source: reviewer, created: created)
}

private func handle(_ request: ReminderRequest, book: ReminderBook, jiraSite: String? = nil) -> (reply: NoticeReply, book: ReminderBook) {
    ReminderLogic.handle(request, book: book, addedBy: "Reviewer", jiraSite: jiraSite, now: now, timeZone: stockholm)
}

private func draft(_ args: [String: Any]) -> Result<ReminderDraft, NoticeError> {
    ReminderLogic.draft(args, now: now, timeZone: stockholm)
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reminders-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

let reminderTests: [(name: String, run: () throws -> Void)] = [
    ("reminders: due is read as notify's at, and a date alone is an all-day due date from today on", {
        func due(_ text: String) -> Result<ReminderDue, NoticeError> { ReminderLogic.due(text, now: now, timeZone: stockholm) }
        check((try? due("13:15").get()) == ReminderDue(date: utc("2026-11-12T12:15:00Z")), "HH:mm today with a time")
        check((try? due("2026-11-13T09:00").get()) == ReminderDue(date: utc("2026-11-13T08:00:00Z")), "ISO local")
        check((try? due("2026-11-13").get()) == ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true), "a day, Stockholm midnight")
        check((try? due("2026-11-12").get())?.allDay == true, "today is fine for a day")
        func problem(_ text: String) -> String {
            if case .failure(let error) = due(text) { return error.message }
            return ""
        }
        check(problem("2026-11-11") == "due 2026-11-11 is in the past.", problem("2026-11-11"))
        check(problem("2026-12-20").contains("30 days"), problem("2026-12-20"))
        check(problem("2026-11-12T08:00").hasPrefix("due 2026-11-12T08:00 is in the past"), problem("2026-11-12T08:00"))
        check(problem("someday").hasPrefix("due must be an ISO 8601"), problem("someday"))
        check((try? ReminderLogic.dueBefore("2026-11-13", now: now, timeZone: stockholm).get()) == utc("2026-11-13T23:00:00Z"), "a day counts in full")
        check((try? ReminderLogic.dueBefore("2026-11-01T10:00", now: now, timeZone: stockholm).get()) == utc("2026-11-01T09:00:00Z"), "past is fine")
        check((try? ReminderLogic.dueBefore("whenever", now: now, timeZone: stockholm).get()) == nil, "unreadable")
    }),

    ("reminders: add_reminder's arguments become a draft, with the link and priority checked", {
        let made = try draft(["title": " Review the PR ", "notes": "Before standup", "due": "2026-11-13", "link": "acme/api#7", "priority": "HIGH"]).get()
        check(made == ReminderDraft(title: "Review the PR", notes: "Before standup", due: ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true),
                                    link: "acme/api#7", priority: .high), "\(made)")
        check(try draft(["title": "x"]).get() == ReminderDraft(title: "x"), "only a title")
        for link in ["https://github.com/acme/api/pull/7", "ACME-1234", "https://acme.atlassian.net/browse/ACME-1", "https://example.com/a", "meeting:42",
                     "https://acme.slack.com/archives/C0ACME1/p1730000000123456"] {
            check((try? draft(["title": "x", "link": link]).get()) != nil, link)
        }
        for bad: [String: Any] in [[:], ["title": " "], ["title": String(repeating: "a", count: 200)], ["title": "x", "priority": "urgent"],
                                   ["title": "x", "link": "main:work"], ["title": "x", "link": "ftp://x"], ["title": "x", "due": "yesterday"],
                                   ["title": "x", "notes": String(repeating: "a", count: 1001)]] {
            check((try? draft(bad).get()) == nil, "refused: \(bad)")
        }
    }),

    ("reminders: a link becomes a source of the right kind, and opens where it can", {
        check(ReminderSource.parse("acme/api#7") == pullRequest && ReminderSource.parse("https://github.com/acme/api/pull/7/files") == pullRequest, "pull request")
        check(pullRequest.reference == "acme/api#7" && pullRequest.label == "acme/api#7" && pullRequest.kind.rawValue == "github_pr", "reference")
        check(ReminderSource.parse(" acme-9 ") == .jira(key: "ACME-9"), "any case")
        check(ReminderSource.parse("ACME-9") == .jira(key: "ACME-9"), "jira key")
        check(ReminderSource.parse("https://acme.atlassian.net/browse/ACME-9") == .jira(key: "ACME-9"), "jira url on atlassian.net")
        check(ReminderSource.parse("https://jira.acme.com/browse/ACME-9", jiraSite: "jira.acme.com") == .jira(key: "ACME-9"), "jira url on the set up site")
        check(ReminderSource.parse("https://jira.acme.com/browse/ACME-9")?.kind == .url, "another host is a page")
        let slack = "https://acme.slack.com/archives/C0ACME1/p1730000000123456"
        check(ReminderSource.parse(slack)?.kind == .slack && ReminderSource.parse(slack)?.reference == slack, "slack message")
        check(ReminderSource.parse("meeting:42") == .meeting(id: 42) && ReminderSource.meeting(id: 42).reference == "42", "meeting")
        check(ReminderSource.parse("https://example.com/a")?.kind == .url && ReminderSource.parse("https://example.com/a")?.label == "example.com", "page")
        check(ReminderSource.parse("http://example.com") == nil && ReminderSource.parse("ftp://x") == nil && ReminderSource.parse("main:work") == nil, "refused")
        check(pullRequest.url(jiraSite: nil)?.absoluteString == "https://github.com/acme/api/pull/7", "pull request page")
        check(ReminderSource.jira(key: "ACME-1").url(jiraSite: "acme.atlassian.net")?.absoluteString == "https://acme.atlassian.net/browse/ACME-1", "jira page")
        check(ReminderSource.jira(key: "ACME-1").url(jiraSite: nil) == nil && ReminderSource.meeting(id: 1).url(jiraSite: nil) == nil, "no page without a site, for a meeting")
        check(ReminderPriority(eventKit: 1) == .high && ReminderPriority(eventKit: 0) == .none && ReminderPriority(eventKit: 7) == .low, "EventKit priorities")
    }),

    ("reminders: the book adds under short ids, completes, deletes and drops old completed ones", {
        var book = ReminderBook()
        let first = book.add(reminder("First"))
        let second = book.add(reminder("Second", due: ReminderDue(date: now)))
        check(first.id.count == 8 && first.id != second.id && book.reminder(first.id)?.title == "First", "ids")
        check(book.open.map(\.title) == ["Second", "First"], "due first")
        check(book.complete(first.id, now: now) && !book.complete("nope", now: now) && book.open.map(\.title) == ["Second"], "completed")
        check(book.reminder(first.id)?.completed == now, "kept with the time")
        book.complete(first.id, now: now.addingTimeInterval(100))
        check(book.reminder(first.id)?.completed == now, "completing twice keeps the first time")
        book.prune(now: now.addingTimeInterval(29 * 86_400))
        check(book.reminders.count == 2, "recent completed stays")
        book.prune(now: now.addingTimeInterval(31 * 86_400))
        check(book.reminders.map(\.title) == ["Second"], "old completed goes")
        book.update(second.id) { $0.title = "Renamed" }
        book.delete(second.id)
        check(book.reminders.isEmpty, "deleted")
    }),

    ("reminders: the book is saved and read back with its sources, and an unreadable file is kept aside", {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sub").appendingPathComponent(ReminderBook.fileName)
        check(ReminderBook.load(from: file) == ReminderBook(), "missing is empty")
        var book = ReminderBook()
        book.add(Reminder(id: "", title: "Review", notes: "Soon", due: ReminderDue(date: utc("2026-11-13T08:00:00Z")), priority: .high, created: now,
                          source: pullRequest, addedBy: "Reviewer"))
        book.add(Reminder(id: "", title: "Call", due: ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true), created: now, completed: now,
                          source: ReminderSource(kind: .slack, reference: "https://acme.slack.com/archives/C0ACME1/p1730000000123456", title: "Slack #dev")))
        try book.save(to: file)
        check(ReminderBook.load(from: file) == book, "round trip")
        try Data("not json".utf8).write(to: file)
        check(ReminderBook.load(from: file) == ReminderBook(), "unreadable is empty")
        check(!FileManager.default.fileExists(atPath: file.path)
              && FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("reminders.unreadable.json").path), "kept aside")
    }),

    ("reminders: the list groups by when they are due, overdue first, and the labels say today and tomorrow", {
        let all = [reminder("Anytime"), reminder("Tomorrow", due: ReminderDue(date: utc("2026-11-13T08:00:00Z"))),
                   reminder("Today all day", due: ReminderDue(date: utc("2026-11-11T23:00:00Z"), allDay: true)),
                   reminder("Later today", due: ReminderDue(date: utc("2026-11-12T12:15:00Z"))),
                   reminder("Earlier today", due: ReminderDue(date: utc("2026-11-12T08:00:00Z"))),
                   reminder("Yesterday", due: ReminderDue(date: utc("2026-11-10T23:00:00Z"), allDay: true))]
        let sections = ReminderLogic.sections(all, now: now, timeZone: stockholm)
        check(sections.map(\.section) == [.overdue, .today, .upcoming, .anytime], "\(sections.map(\.section))")
        check(sections.map { $0.reminders.map(\.title) } == [["Yesterday", "Earlier today"], ["Today all day", "Later today"], ["Tomorrow"], ["Anytime"]],
              "\(sections.map { $0.reminders.map(\.title) })")
        check(ReminderLogic.sections([], now: now).isEmpty, "empty")
        func label(_ due: ReminderDue) -> String { ReminderLogic.dueLabel(due, now: now, timeZone: stockholm, locale: Locale(identifier: "en_GB")) }
        check(label(ReminderDue(date: utc("2026-11-12T12:15:00Z"))) == "Today 13:15", label(ReminderDue(date: utc("2026-11-12T12:15:00Z"))))
        check(label(ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true)) == "Tomorrow", "tomorrow")
        check(label(ReminderDue(date: utc("2026-11-19T23:00:00Z"), allDay: true)) == "20 Nov", label(ReminderDue(date: utc("2026-11-19T23:00:00Z"), allDay: true)))
        check(label(ReminderDue(date: utc("2026-11-20T08:00:00Z"))) == "20 Nov 09:00", label(ReminderDue(date: utc("2026-11-20T08:00:00Z"))))
    }),

    ("reminders: the menu choices mean a day, an hour on, tomorrow morning, next Monday morning or no date", {
        func due(_ preset: ReminderPreset) -> ReminderDue? { ReminderLogic.due(preset, now: now, timeZone: stockholm) }
        check(due(.today) == ReminderDue(date: utc("2026-11-11T23:00:00Z"), allDay: true), "today")
        check(due(.inAnHour) == ReminderDue(date: utc("2026-11-12T10:00:00Z")), "in an hour")
        check(due(.tomorrow) == ReminderDue(date: utc("2026-11-13T08:00:00Z")), "tomorrow at nine")
        check(due(.nextWeek) == ReminderDue(date: utc("2026-11-16T08:00:00Z")), "Monday at nine")
        check(due(.noDate) == nil, "no date")
        let sunday = utc("2026-11-15T09:00:00Z"), monday = utc("2026-11-16T09:00:00Z")
        check(ReminderLogic.due(.nextWeek, now: sunday, timeZone: stockholm)?.date == utc("2026-11-16T08:00:00Z"), "Sunday: the next day")
        check(ReminderLogic.due(.nextWeek, now: monday, timeZone: stockholm)?.date == utc("2026-11-23T08:00:00Z"), "Monday: a week on")
    }),

    ("reminders: only an open reminder with a time still to come gets a system notification", {
        let timed = reminder("Call", due: ReminderDue(date: utc("2026-11-12T12:15:00Z")))
        check(ReminderLogic.alarm(for: timed, now: now) == utc("2026-11-12T12:15:00Z"), "timed")
        check(ReminderLogic.alarm(for: timed, now: utc("2026-11-12T13:00:00Z")) == nil, "past")
        var done = timed
        done.completed = now
        check(ReminderLogic.alarm(for: done, now: now) == nil, "completed")
        check(ReminderLogic.alarm(for: reminder("Day", due: ReminderDue(date: utc("2026-11-13T23:00:00Z"), allDay: true)), now: now) == nil, "all day")
        check(ReminderLogic.alarm(for: reminder("None"), now: now) == nil, "no due")
    }),

    ("reminders: an open one with the same title and due is a duplicate", {
        let at = utc("2026-11-12T12:15:00Z")
        var closed = reminder("Done")
        closed.completed = now
        let open = [reminder("Review PR", due: ReminderDue(date: at)), reminder("Call", due: ReminderDue(date: utc("2026-11-12T23:00:00Z"), allDay: true)), closed]
        func duplicate(_ title: String, due: ReminderDue? = nil) -> String? {
            ReminderLogic.duplicate(of: title, due: due, in: open, timeZone: stockholm)?.id
        }
        check(duplicate("review pr", due: ReminderDue(date: at.addingTimeInterval(20))) == "Review PR", "same minute, any case")
        check(duplicate("Review PR", due: ReminderDue(date: at.addingTimeInterval(3600))) == nil, "another time")
        check(duplicate("Review PR") == nil, "no due against a due one")
        check(duplicate("Call", due: ReminderDue(date: utc("2026-11-13T10:00:00Z"), allDay: true)) == "Call", "same day")
        check(duplicate("Call", due: ReminderDue(date: utc("2026-11-13T10:00:00Z"))) == nil, "a time is not all day")
        check(duplicate("Done") == nil, "a completed one is not")
    }),

    ("reminders: the import keeps the due date and priority, turns the url into the source and the old note lines into the sender", {
        let imported = [ImportedReminder(title: " Merge it ", notes: "Do it now\nhttps://github.com/acme/api/pull/7\nAdded by Main \u{00B7} work",
                                         url: "https://github.com/acme/api/pull/7", due: ReminderDue(date: utc("2026-11-13T08:00:00Z")), priority: .high,
                                         created: utc("2026-11-01T08:00:00Z")),
                        ImportedReminder(title: "Buy milk"), ImportedReminder(title: "  "), ImportedReminder(title: "buy MILK")]
        var existing = ReminderBook()
        existing.add(reminder("Already here"))
        let book = ReminderLogic.importing(imported + [ImportedReminder(title: "already here")], into: existing, now: now, timeZone: stockholm)
        check(book.reminders.map(\.title) == ["Already here", "Merge it", "Buy milk"], "\(book.reminders.map(\.title))")
        let merge = book.reminders[1]
        check(merge.notes == "Do it now" && merge.addedBy == "Main \u{00B7} work" && merge.source == pullRequest && merge.priority == .high, "\(merge)")
        check(merge.created == utc("2026-11-01T08:00:00Z") && merge.due?.date == utc("2026-11-13T08:00:00Z") && merge.isOpen, "dates")
        check(book.reminders[2].created == now && book.reminders[2].source == nil && book.reminders[2].notes == nil, "defaults")
        check(ReminderLogic.importing(imported, into: book, now: now, timeZone: stockholm) == book, "importing twice adds nothing")
        check(Set(book.reminders.map(\.id)).count == 3 && book.reminders.allSatisfy { $0.id.count == 8 || $0.id == "Already here" }, "ids")
    }),

    ("reminders: the app adds, dedupes, lists and completes, and says why when it cannot", {
        let review = ReminderDraft(title: "Review", notes: "Soon", due: ReminderDue(date: utc("2026-11-12T12:15:00Z")), link: "ACME-9", priority: .medium)
        let added = handle(request(.add, draft: review), book: ReminderBook(), jiraSite: "acme.atlassian.net")
        check(added.reply.ok && added.reply.message == "Added \"Review\", due 2026-11-12 13:15; id \(added.reply.notice ?? "").", added.reply.message)
        let id = added.reply.notice ?? ""
        check(added.book.reminder(id) == Reminder(id: id, title: "Review", notes: "Soon", due: review.due, priority: .medium, created: now,
                                                  source: .jira(key: "ACME-9"), addedBy: "Reviewer"), "\(String(describing: added.book.reminder(id)))")
        let again = handle(request(.add, draft: ReminderDraft(title: "review", due: review.due)), book: added.book)
        check(again.reply.ok && again.reply.notice == id && again.reply.message.contains("not added again") && again.book.reminders.count == 1, again.reply.message)
        var book = again.book
        book = handle(request(.add, draft: ReminderDraft(title: "Someday", link: "https://github.com/acme/api/pull/7")), book: book).book
        let all = handle(request(.list), book: book).reply.message
        let someday = book.reminders.last?.id ?? ""
        check(all == "- id \(id) \u{00B7} Review \u{00B7} due 2026-11-12 13:15 \u{00B7} medium priority \u{00B7} jira ACME-9 \u{00B7} added by Reviewer\n"
              + "- id \(someday) \u{00B7} Someday \u{00B7} github_pr acme/api#7 \u{00B7} added by Reviewer\n", all)
        check(handle(request(.list, dueBefore: utc("2026-11-12T10:00:00Z")), book: book).reply.message == "No open reminders.\n", "none due yet")

        let done = handle(request(.complete, reminder: id), book: book)
        check(done.reply.message == "Completed \"Review\"." && done.book.reminder(id)?.completed == now, done.reply.message)
        check(handle(request(.complete, reminder: id), book: done.book).reply.message.contains("already completed"), "twice")
        check(!handle(request(.complete, reminder: "nope"), book: book).reply.ok, "unknown id")
        check(handle(request(.list), book: done.book).reply.message.contains("Someday") && !handle(request(.list), book: done.book).reply.message.contains("id \(id)"), "completed is not listed")
        check(handle(request(.list, created: now.addingTimeInterval(-600)), book: book).reply.message == "The request is too old.", "stale")
        check(handle(request(.add), book: book).reply.message == "title is required.", "no draft")
    }),

    ("reminders: the MCP tools hand requests to the app, which answers from its book", {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        let claude = NoticeSource(session: "s1", cwd: "/Users/me/git/api")
        let sources = MCPServer.NoticeSources(file: root.appendingPathComponent(NoticeLogic.fileName), inbox: inbox, replyTimeout: 3,
                                              timeZone: stockholm, source: { claude })
        let tools = MCPServer.reminderTools(sources: sources, now: { now })
        check(tools.map(\.name) == ["add_reminder", "reminders", "complete_reminder"] && tools.map(\.readOnly) == [false, true, false], "\(tools.map(\.name))")
        check(tools.map(\.name).allSatisfy(MCPServer.toolNames.contains), "listed")
        func run(_ name: String, _ args: [String: Any] = [:]) -> Result<String, Error> {
            Result { try tools.first { $0.name == name }!.run(args) }
        }
        let book = Box<ReminderBook>()
        book.value = ReminderBook()
        let received = Box<[ReminderRequest]>()
        received.value = []
        let app = Thread {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
                if let name = names.first(where: ReminderLogic.isRequest),
                   let data = try? Data(contentsOf: inbox.appendingPathComponent(name)),
                   let request = AgentInbox.decode(ReminderRequest.self, from: data) {
                    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(name))
                    received.value?.append(request)
                    let result = ReminderLogic.handle(request, book: book.value ?? ReminderBook(), addedBy: request.source.label(titles: [:]), jiraSite: nil,
                                                      now: now, timeZone: stockholm)
                    book.value = result.book
                    try? AgentInbox.encode(result.reply).write(to: inbox.appendingPathComponent(AgentInbox.replyName(request.id)))
                    if request.action == .complete { return }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        app.start()
        let added = (try? run("add_reminder", ["title": "Merge it", "due": "2026-11-13", "link": "https://github.com/acme/api/pull/7"]).get()) ?? ""
        let id = book.value?.reminders.first?.id ?? ""
        check(added == "Added \"Merge it\", due 2026-11-13; id \(id).", added)
        check(received.value?.first?.source == claude && received.value?.first?.draft?.due?.allDay == true, "request")
        check(book.value?.reminders.first?.source == pullRequest && book.value?.reminders.first?.addedBy == "Claude Code \u{00B7} api", "\(String(describing: book.value?.reminders.first))")
        check((try? run("add_reminder", ["title": "x", "due": "yesterday"]).get()) == nil, "bad due refused before the app is asked")
        let listed = (try? run("reminders", ["due_before": "2026-11-13"]).get()) ?? ""
        check(listed.hasPrefix("Filtered by due_before \u{201C}2026-11-13\u{201D}\n- id \(id) \u{00B7} Merge it \u{00B7} due 2026-11-13"), listed)
        let narrowed = (try? run("reminders", ["due_after": "2026-11-13", "priority": "none", "query": "merge", "source_kind": "github_pr", "source": "acme/api#7"]).get()) ?? ""
        check(narrowed.hasPrefix("Filtered by due_after") && narrowed.contains("source_kind") && narrowed.contains("github_pr acme/api#7"), narrowed)
        check((try? run("reminders", ["source_kind": "jira"]).get())?.hasSuffix("No open reminders.\n") == true, "another source kind finds nothing")
        check((try? run("reminders", ["priority": "urgent"]).get()) == nil, "unknown priority refused before the app is asked")
        check((try? run("reminders", ["source_kind": "email"]).get()) == nil, "unknown source kind refused before the app is asked")
        check((try? run("complete_reminder", ["id": id]).get()) == "Completed \"Merge it\".", "completed")

        let quiet = MCPServer.reminderTools(sources: MCPServer.NoticeSources(inbox: inbox, replyTimeout: 0.3, source: { claude }), now: { now })
        if case .failure(let error) = Result(catching: { try quiet[0].run(["title": "anyone?"]) }) {
            check(error.localizedDescription.contains("did not take the reminder") && error.localizedDescription.contains("Is the app running?"),
                  error.localizedDescription)
        } else {
            check(false, "no app, no success")
        }
        check(((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).isEmpty, "inbox cleaned up")
    }),
]
