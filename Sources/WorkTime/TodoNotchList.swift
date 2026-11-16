import SwiftUI

@MainActor
final class TodoModel: ObservableObject {
    static let shared = TodoModel()
    @Published private(set) var book = ReminderBook()
    @Published private(set) var meeting: [MeetingTodo] = []
    var openMeeting: (Int64) -> Void = { _ in }
    private var file: URL?
    private var store: MeetingStore?
    private var observer: NSObjectProtocol?

    var reminders: [Reminder] { book.open }

    func start(store: MeetingStore, file: URL = AppPaths.reminders) {
        self.store = store
        self.file = file
        book = ReminderBook.load(from: file)
        book.prune(now: Date())
        observer = NotificationCenter.default.addObserver(forName: MeetingStore.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TodoModel.shared.reloadMeetings() }
        }
        reloadMeetings()
        book.reminders.forEach(syncAlarm)
        importFromApple()
    }

    /// Takes the open Apple Reminders over once, the first time this version runs; with no permission there is nothing to take.
    private func importFromApple() {
        guard !UserDefaults.standard.bool(forKey: AppleRemindersImport.doneKey) else { return }
        UserDefaults.standard.set(true, forKey: AppleRemindersImport.doneKey)
        Task {
            let items = await AppleRemindersImport.incomplete()
            guard !items.isEmpty else { return }
            apply(ReminderLogic.importing(items, into: book, now: Date(), jiraSite: JiraModel.shared.site))
        }
    }

    func reloadMeetings() {
        meeting = (try? store?.openActionItems(limit: 100, since: TodoLogic.meetingCutoff(now: Date()))) ?? []
    }

    private func apply(_ new: ReminderBook) {
        guard new != book else { return }
        let before = book
        withAnimation(.easeOut(duration: 0.2)) { book = new }
        if let file { try? new.save(to: file) }
        for reminder in new.reminders where before.reminder(reminder.id) != reminder { syncAlarm(reminder) }
        for reminder in before.reminders where new.reminder(reminder.id) == nil { Notifier.withdrawReminderAlarm(reminder.id) }
    }

    private func syncAlarm(_ reminder: Reminder) {
        if let date = ReminderLogic.alarm(for: reminder, now: Date()) {
            Notifier.postReminderAlarm(reminder, at: date)
        } else {
            Notifier.withdrawReminderAlarm(reminder.id)
        }
    }

    func add(_ input: String) {
        guard let title = TodoLogic.text(input) else { return }
        remind(title: title, source: nil, preset: .noDate)
    }

    /// A reminder about something, due as the preset says; the same one still open is not made twice.
    func remind(title: String, source: ReminderSource?, preset: ReminderPreset) {
        guard let title = TodoLogic.text(title).map({ String($0.prefix(NoticeLogic.titleLimit)) }) else { return }
        let due = ReminderLogic.due(preset, now: Date())
        guard ReminderLogic.duplicate(of: title, due: due, in: book.reminders) == nil else { return }
        var new = book
        new.add(Reminder(id: "", title: title, due: due, created: Date(), source: source))
        apply(new)
    }

    func complete(_ id: TodoRow.ID) {
        switch id {
        case .todo(let id):
            var new = book
            new.complete(id, now: Date())
            apply(new)
        case .meeting(let id):
            withAnimation(.easeOut(duration: 0.25)) { meeting.removeAll { $0.id == id } }
            try? store?.setChecked(actionItem: id, true)
        }
    }

    func delete(_ id: String) {
        var new = book
        new.delete(id)
        apply(new)
    }

    func rename(_ id: String, to input: String) {
        guard let title = TodoLogic.text(input) else { return }
        var new = book
        new.update(id) { $0.title = String(title.prefix(NoticeLogic.titleLimit)) }
        apply(new)
    }

    func setDue(_ id: String, _ preset: ReminderPreset) {
        var new = book
        new.update(id) { $0.due = ReminderLogic.due(preset, now: Date()) }
        apply(new)
    }

    /// Shows what a reminder is about: the pull request, ticket, Slack message, meeting or page.
    func open(_ source: ReminderSource) {
        switch source.kind {
        case .githubPR: GitHubLink.pasted(source.reference).map { AgentModel.openPullRequestLink?($0) }
        case .meeting: Int64(source.reference).map(openMeeting)
        case .jira, .slack, .url: source.url(jiraSite: JiraModel.shared.site).map { _ = NSWorkspace.shared.open($0) }
        }
    }

    /// A clicked notification of a reminder: its source, or else the notch bar.
    func openFromNotification(_ id: String) {
        if let source = book.reminder(id)?.source { open(source) } else { AskPanel.shared.peek(for: 20) }
    }

    /// An agent's add_reminder, reminders or complete_reminder, handed over by the MCP server through the agent inbox.
    func handle(_ request: ReminderRequest) -> NoticeReply {
        let result = ReminderLogic.handle(request, book: book, addedBy: request.source.label(titles: NoticeCenter.shared.titles()),
                                          jiraSite: JiraModel.shared.site, now: Date())
        apply(result.book)
        return result.reply
    }

    #if DEBUG
    /// Shows made-up items without a file or a database, for the previews.
    func showSample(reminders: [Reminder], meeting: [MeetingTodo]) {
        book = ReminderBook(reminders: reminders)
        self.meeting = meeting
    }
    #endif
}

enum TodoRow {
    enum ID: Hashable {
        case todo(String)
        case meeting(Int64)
    }
}

/// The notch bar's todo list: round checkboxes that fill and drop out, the reminders by when they are due, each with a chip
/// that opens what it is about, and a New Reminder row at the end.
struct TodoNotchList: View {
    static let completionDelay = 1.0
    let onHold: (Bool) -> Void
    let onType: (String) -> Void
    @ObservedObject private var model = TodoModel.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @State private var checking: Set<TodoRow.ID> = []
    @State private var adding = false
    @State private var draft = ""
    @State private var editing: String?
    @State private var edited = ""
    @FocusState private var focused: Bool
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reminders").font(.title3.bold()).foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(model.reminders.count)").font(.title3.bold()).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            NotchScroll { rows }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onDisappear { end(keep: true) }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !notices.waiting.isEmpty {
                heading("From agents", top: 0)
                ForEach(notices.waiting) { notice in
                    NoticeRow(notice: notice, open: { notices.open(notice.id) }, remove: { notices.dismiss(notice.id) })
                    separator
                }
            }
            if !notices.pending.isEmpty {
                heading("Scheduled", top: notices.waiting.isEmpty ? 0 : 10)
                ForEach(notices.pending) { notice in
                    NoticeRow(notice: notice, open: nil, remove: { notices.dismiss(notice.id) })
                    separator
                }
            }
            reminderRows
            newReminder
            if !model.meeting.isEmpty {
                heading("From meetings", top: 14)
                ForEach(model.meeting.prefix(TodoLogic.meetingLimit)) { item in
                    row(.meeting(item.id), text: item.task) {
                        Text([item.owner, item.title].compactMap { $0 }.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contextMenu { RemindMeMenu(title: item.task, source: .meeting(id: item.meeting, title: item.title)) }
                    if item.id != model.meeting.prefix(TodoLogic.meetingLimit).last?.id { separator }
                }
            }
        }
    }

    @ViewBuilder private var reminderRows: some View {
        let now = Date()
        let sections = ReminderLogic.sections(model.reminders, now: now)
        let titled = sections.count > 1 || sections.first.map { $0.section != .anytime } ?? false
        let alone = notices.waiting.isEmpty && notices.pending.isEmpty
        ForEach(sections, id: \.section) { group in
            if titled { heading(group.section.title, top: alone && group.section == sections.first?.section ? 0 : 10, overdue: group.section == .overdue) }
            ForEach(group.reminders.prefix(TodoLogic.todoLimit)) { reminder in
                reminderRow(reminder, now: now)
                separator
            }
        }
    }

    private func reminderRow(_ reminder: Reminder, now: Date) -> some View {
        let id = TodoRow.ID.todo(reminder.id)
        let overdue = ReminderLogic.section(of: reminder, now: now) == .overdue
        return row(id, text: reminder.title, editing: editing == reminder.id) {
            HStack(spacing: 6) {
                if let due = reminder.due {
                    Text(ReminderLogic.dueLabel(due, now: now)).foregroundStyle(overdue ? Color.red : .secondary)
                }
                if let source = reminder.source { SourceChip(source: source) { model.open(source) } }
                if let addedBy = reminder.addedBy { Text(addedBy).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .font(.caption)
        }
        .contextMenu {
            Button("Edit") { beginEdit(reminder) }
            Menu("Set Due") {
                ForEach(ReminderPreset.allCases, id: \.self) { preset in Button(preset.title) { model.setDue(reminder.id, preset) } }
            }
            if let source = reminder.source { Button("Open \(source.label)") { model.open(source) } }
            Divider()
            Button("Delete", role: .destructive) { model.delete(reminder.id) }
        }
    }

    private func heading(_ text: String, top: CGFloat, overdue: Bool = false) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(overdue ? Color.red : .secondary)
            .padding(.horizontal, 8)
            .padding(.top, top)
            .padding(.bottom, 4)
    }

    private var separator: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 38)
    }

    private func row<Detail: View>(_ id: TodoRow.ID, text: String, editing isEditing: Bool = false,
                                   @ViewBuilder detail: () -> Detail) -> some View {
        let checked = checking.contains(id)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { toggle(id) } label: { CheckCircle(checked: checked) }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                if isEditing, case .todo(let reminder) = id {
                    TextField("Reminder", text: $edited)
                        .textFieldStyle(.plain)
                        .focused($editFocused)
                        .onSubmit { endEdit(reminder, save: true) }
                        .onExitCommand { endEdit(reminder, save: false) }
                } else {
                    Text(text).lineLimit(2).foregroundStyle(checked ? .secondary : .primary)
                }
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .opacity(checked ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: checked)
        .transition(.opacity)
    }

    private var newReminder: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(adding ? Color.secondary : Color.accentColor)
            if adding {
                TextField("New Reminder", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { end(keep: false) }
                    .onChange(of: draft) { _, text in onType(text) }
            } else {
                Text("New Reminder").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: begin)
    }

    private func toggle(_ id: TodoRow.ID) {
        if checking.remove(id) != nil { return }
        checking.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay) {
            guard checking.remove(id) != nil else { return }
            model.complete(id)
        }
    }

    private func beginEdit(_ reminder: Reminder) {
        edited = reminder.title
        editing = reminder.id
        onHold(true)
        DispatchQueue.main.async { editFocused = true }
    }

    private func endEdit(_ id: String, save: Bool) {
        if save { model.rename(id, to: edited) }
        editing = nil
        editFocused = false
        onHold(false)
    }

    private func begin() {
        guard !adding else { return }
        adding = true
        onHold(true)
        DispatchQueue.main.async { focused = true }
    }

    private func submit() {
        model.add(draft)
        draft = ""
        DispatchQueue.main.async { focused = true }
    }

    private func end(keep: Bool) {
        guard adding else { return }
        if keep { model.add(draft) }
        draft = ""
        adding = false
        focused = false
        onHold(false)
    }
}

/// A notification from an agent: click to open its link, the cross to dismiss it, or to cancel it while it is scheduled.
private struct NoticeRow: View {
    let notice: AgentNotice
    let open: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: open == nil ? "clock" : notice.urgency == .high ? "exclamationmark.circle.fill" : "bell.fill")
                .font(.system(size: 14))
                .foregroundStyle(notice.urgency == .high ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help(open == nil ? "Cancel" : "Dismiss")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { open?() }
        .transition(.opacity)
    }

    private var detail: String {
        var parts = [notice.source.title ?? notice.source.label(titles: [:])]
        let time = notice.date.formatted(date: Calendar.current.isDateInToday(notice.date) ? .omitted : .abbreviated, time: .shortened)
        parts.append(notice.state == .missed ? "missed \(time)" : time)
        if let body = notice.body { parts.append(body) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

private struct CheckCircle: View {
    let checked: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(checked ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
            if checked {
                Circle().fill(Color.accentColor).padding(3)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: checked)
    }
}
