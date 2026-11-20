import SwiftUI
import UserNotifications

@MainActor
final class TodoModel: ObservableObject {
    static let shared = TodoModel()
    @Published private(set) var book = ReminderBook()
    @Published private(set) var meeting: [MeetingTodo] = []
    @Published private(set) var decisions = SuggestionDecisions()
    var openMeeting: (Int64) -> Void = { _ in }
    var showPage: () -> Void = {}
    /// The reminder or suggestion the Reminders page scrolls to and highlights, until it has.
    @Published var focus: String?
    private var file: URL?
    private var decisionsFile: URL?
    private var store: MeetingStore?
    private var observer: NSObjectProtocol?

    var reminders: [Reminder] { book.open }
    var completed: [Reminder] { SuggestionLogic.completed(book.reminders) }
    /// Meeting action items waiting for the user to approve or dismiss them.
    var suggestions: [MeetingTodo] { SuggestionLogic.suggestions(meeting, decisions: decisions) }
    var dismissed: [MeetingTodo] { SuggestionLogic.dismissed(meeting, decisions: decisions) }

    func start(store: MeetingStore, file: URL = AppPaths.reminders, decisionsFile: URL = AppPaths.reminderSuggestions) {
        self.store = store
        self.file = file
        self.decisionsFile = decisionsFile
        book = ReminderBook.load(from: file)
        decisions = SuggestionDecisions.load(from: decisionsFile)
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

    /// Shows the Reminders page, scrolled to `id` when given.
    func reveal(_ id: String? = nil) {
        focus = id
        showPage()
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
    /// Returns the reminder's id, also when the same one was already open.
    @discardableResult
    func remind(title: String, source: ReminderSource?, preset: ReminderPreset) -> String? {
        guard let title = TodoLogic.text(title).map({ String($0.prefix(NoticeLogic.titleLimit)) }) else { return nil }
        let due = ReminderLogic.due(preset, now: Date())
        if let same = ReminderLogic.duplicate(of: title, due: due, in: book.reminders) { return same.id }
        var new = book
        let saved = new.add(Reminder(id: "", title: title, due: due, created: Date(), source: source))
        apply(new)
        return saved.id
    }

    func complete(_ id: String) {
        var new = book
        new.complete(id, now: Date())
        apply(new)
        NoticeCenter.shared.resolveAsk(reminder: id)
    }

    func reopen(_ id: String) {
        var new = book
        new.update(id) { $0.completed = nil }
        apply(new)
    }

    /// Makes a suggested action item a regular reminder, due as the preset says, unless the same one is already open.
    func approve(_ item: MeetingTodo, preset: ReminderPreset = .noDate) {
        let reminder = SuggestionLogic.reminder(from: item, due: ReminderLogic.due(preset, now: Date()), now: Date())
        if ReminderLogic.duplicate(of: reminder.title, due: reminder.due, in: book.reminders) == nil {
            var new = book
            new.add(reminder)
            apply(new)
        }
        decide { $0.approved.insert(item.id) }
    }

    func dismiss(_ item: MeetingTodo) { decide { $0.dismissed.insert(item.id) } }

    func restore(_ item: MeetingTodo) { decide { $0.restore(item.id) } }

    /// A decision put aside without an answer: its reminder is done with, or one is made and done, so it stays in Resolved.
    func resolveWithoutAnswer(_ notice: AgentNotice) {
        if let reminder = notice.ask?.reminder, book.reminder(reminder) != nil { return complete(reminder) }
        let source = Decisions.resolvedSource(link: notice.link, jiraSite: JiraModel.shared.site)
        guard let id = remind(title: Decisions.readable(notice.title), source: source, preset: .noDate) else { return }
        complete(id)
    }

    func clearCompleted() {
        var new = book
        new.clearCompleted()
        apply(new)
    }

    private func decide(_ change: (inout SuggestionDecisions) -> Void) {
        var new = decisions
        change(&new)
        withAnimation(.easeOut(duration: 0.2)) { decisions = new }
        if let decisionsFile { try? new.save(to: decisionsFile) }
    }

    /// Points the reminder at the Jira ticket made from it.
    func attach(ticket key: String, summary: String, to id: String, jiraSite: String?) {
        var new = book
        new.update(id) { $0 = JiraCreate.linking($0, ticket: key, summary: summary, jiraSite: jiraSite) }
        apply(new)
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

    func setDue(_ id: String, _ preset: ReminderPreset) { setDue(id, ReminderLogic.due(preset, now: Date())) }

    func setDue(_ id: String, _ due: ReminderDue?) {
        var new = book
        new.update(id) { $0.due = due }
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
        if let notice = ReminderLogic.immediateNotice(for: request) { return NoticeCenter.shared.handle(notice) }
        let result = ReminderLogic.handle(request, book: book, addedBy: request.source.label(titles: NoticeCenter.shared.titles()),
                                          jiraSite: JiraModel.shared.site, now: Date())
        apply(result.book)
        return result.reply
    }

    #if DEBUG
    /// Shows made-up items without a file or a database, for the previews.
    func showSample(reminders: [Reminder], meeting: [MeetingTodo]) {
        book = ReminderBook(reminders: reminders)
        decisions = SuggestionDecisions()
        self.meeting = meeting
    }
    #endif
}

/// The notch bar's todo list: the reminders by when they are due, each with a chip that opens what it is about, a New Reminder row,
/// and the meeting action items suggested as reminders.
struct TodoNotchList: View {
    let onOpen: () -> Void
    let onHold: (Bool) -> Void
    let onType: (String) -> Void
    @ObservedObject private var model = TodoModel.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var attention = AgentAttentionCenter.shared
    @ObservedObject private var rowsModel = DecisionRowsModel.shared
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

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
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.downArrow) { keyed { rowsModel.move(1, in: decisionIDs) } }
                .onKeyPress(.upArrow) { keyed { rowsModel.move(-1, in: decisionIDs) } }
                .onKeyPress(.space) { keyed { rowsModel.activate() } }
                .onKeyPress(.return, phases: .down) { press in
                    keyed { press.modifiers.contains(.command) ? rowsModel.runPrimary() : rowsModel.activate() }
                }
                .onAppear {
                    rowsModel.prune(to: decisionIDs)
                    Task { await notices.resolveClosedPullRequests() }
                }
                .onChange(of: decisionIDs) { _, ids in rowsModel.prune(to: ids) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .onDisappear { end(keep: true) }
    }

    /// The decision rows from the top, for the arrow keys: approvals, then each drafted review and each question.
    private var decisionIDs: [String] {
        attention.approvals.map { DecisionIDs.approval($0.id) }
            + notices.waiting.flatMap { notice -> [String] in
                if let reviews = notice.reviews { return reviews.map { DecisionIDs.review($0.id) } }
                return notice.ask == nil ? [] : [DecisionIDs.notice(notice.id)]
            }
    }

    /// A key while the user is not typing a new reminder.
    private func keyed(_ action: () -> Void) -> KeyPress.Result {
        guard !adding, !decisionIDs.isEmpty else { return .ignored }
        action()
        return .handled
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attention.approvals.isEmpty {
                heading("Waiting for you", top: 0)
                ForEach(attention.approvals) { approval in
                    ApprovalRow(approval: approval, onOpen: onOpen)
                    separator
                }
            }
            if !notices.waiting.isEmpty {
                heading("From agents", top: attention.approvals.isEmpty ? 0 : 10)
                ForEach(notices.waiting) { notice in
                    NoticeRow(notice: notice, open: { onOpen(); notices.open(notice.id) }, onOpen: onOpen, answer: { notices.answer(notice.id, yes: $0) },
                              remove: { notices.dismissUnanswered(notice.id) })
                    separator
                }
            }
            if !notices.pending.isEmpty {
                heading("Scheduled", top: notices.waiting.isEmpty ? 0 : 10)
                ForEach(notices.pending) { notice in
                    NoticeRow(notice: notice, open: nil, onOpen: onOpen, answer: nil, remove: { notices.dismiss(notice.id) })
                    separator
                }
            }
            reminderRows
            newReminder
            suggestedRows
            ResolvedReminders(completed: model.completed, dismissed: model.dismissed)
        }
    }

    @ViewBuilder private var reminderRows: some View {
        let now = Date()
        let sections = ReminderLogic.sections(model.reminders, now: now)
        let titled = sections.count > 1 || sections.first.map { $0.section != .anytime } ?? false
        let alone = notices.waiting.isEmpty && notices.pending.isEmpty && attention.approvals.isEmpty
        ForEach(sections, id: \.section) { group in
            if titled { heading(group.section.title, top: alone && group.section == sections.first?.section ? 0 : 10, overdue: group.section == .overdue) }
            ForEach(group.reminders.prefix(TodoLogic.todoLimit)) { reminder in
                ReminderRow(reminder: reminder, now: now, onHold: onHold, onOpen: onOpen)
                separator
            }
        }
    }

    @ViewBuilder private var suggestedRows: some View {
        let items = Array(model.suggestions.prefix(TodoLogic.meetingLimit))
        if !items.isEmpty {
            heading("Suggested from meetings", top: 14)
            ForEach(items) { item in
                SuggestionRow(item: item, onOpen: onOpen)
                if item.id != items.last?.id { separator }
            }
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

/// A notification from an agent: click to open its link, the cross to dismiss it, or to cancel it while it is scheduled. A question or a
/// drafted review waits for an answer: its row opens in place to show everything needed to decide.
private struct NoticeRow: View {
    let notice: AgentNotice
    let open: (() -> Void)?
    let onOpen: () -> Void
    let answer: ((Bool) -> Void)?
    let remove: () -> Void
    @ObservedObject private var model = DecisionRowsModel.shared

    private var id: String { DecisionIDs.notice(notice.id) }

    var body: some View {
        if let reviews = notice.reviews, open != nil, !reviews.isEmpty {
            if reviews.count == 1 {
                ReviewDecisionRow(draft: reviews[0], notice: notice, onOpen: onOpen)
            } else {
                ReviewSetTable(notice: notice, drafts: reviews, onOpen: onOpen, dismiss: remove).padding(.vertical, 6).padding(.horizontal, 8)
            }
        } else if notice.ask != nil, open != nil {
            DecisionRowFrame(id: id, agent: notice.source.agent, primary: { answer?(true) }) { content }
        } else {
            content
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture { open?() }
                .transition(.opacity)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: open == nil ? "clock" : notice.urgency == .high ? "exclamationmark.circle.fill" : "bell.fill")
                .font(.system(size: 14))
                .foregroundStyle(notice.urgency == .high ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Decisions.readable(notice.title)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(notice.ask == nil ? 1 : model.isExpanded(id) ? nil : 3)
                if let ask = notice.ask, let answer {
                    HStack(spacing: 6) {
                        Button(ask.yes) { answer(true) }.buttonStyle(.borderedProminent)
                        Button(ask.no) { answer(false) }.buttonStyle(.bordered)
                        if let open { Button("Open in the app") { onOpen(); open() }.linkButtonStyle() }
                    }
                    .controlSize(.small)
                    .padding(.top, 3)
                    if model.isExpanded(id) { DecisionSectionsView(sections: DecisionDetail.ask(notice)).padding(.top, 4) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if notice.ask != nil { DecisionChevron(id: id) }
            Button(action: remove) { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help(open == nil ? "Cancel" : Decisions.needsAnswer(notice) ? "Dismiss without answering; it stays in Resolved" : "Dismiss")
        }
    }

    private var detail: String {
        var parts = [notice.source.title ?? notice.source.label(titles: [:])]
        let time = notice.date.formatted(date: Calendar.current.isDateInToday(notice.date) ? .omitted : .abbreviated, time: .shortened)
        parts.append(notice.state == .missed ? "missed \(time)" : time)
        if let body = notice.body { parts.append(Decisions.readable(body)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// An agent waiting for approval of a call: the buttons of its notification, answered from here without opening the app. The row opens
/// to show the whole call and why the agent wants it.
private struct ApprovalRow: View {
    let approval: AgentAttentionCenter.Approval
    let onOpen: () -> Void
    @ObservedObject private var model = DecisionRowsModel.shared

    private var id: String { DecisionIDs.approval(approval.id) }

    private var primaryAction: String {
        approval.ticketAsk ? AgentAttention.reuseAction : approval.blocked ? AgentAttention.fixAction : approval.roleTool ? AgentAttention.addToolAction : AgentAttention.allowAction
    }

    var body: some View {
        DecisionRowFrame(id: id, agent: approval.agent, primary: { answer(primaryAction) }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 14)).foregroundStyle(Color.orange).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(approval.title).lineLimit(2)
                    Text(approval.body).font(.caption).foregroundStyle(.secondary).lineLimit(model.isExpanded(id) ? nil : 3)
                    HStack(spacing: 6) {
                        if approval.ticketAsk {
                            Button("Reuse this one") { answer(AgentAttention.reuseAction) }.buttonStyle(.borderedProminent)
                            Button("Start a new one") { answer(AgentAttention.newSessionAction) }.buttonStyle(.bordered)
                            Button("Always reuse") { answer(AgentAttention.alwaysReuseAction) }.buttonStyle(.bordered)
                        } else if approval.blocked {
                            Button("Fix and continue") { answer(AgentAttention.fixAction) }.buttonStyle(.borderedProminent)
                        } else {
                            if approval.roleTool {
                                Button("Add to its tools") { answer(AgentAttention.addToolAction) }.buttonStyle(.borderedProminent)
                                Button("Allow once") { answer(AgentAttention.allowAction) }.buttonStyle(.bordered)
                            } else {
                                Button("Allow once") { answer(AgentAttention.allowAction) }.buttonStyle(.borderedProminent)
                            }
                            if approval.sessionOffered { Button("Allow for this session") { answer(AgentAttention.allowSessionAction) }.buttonStyle(.bordered) }
                            Button("Deny") { answer(AgentAttention.denyAction) }.buttonStyle(.bordered)
                        }
                        Button("Open in the app") { onOpen(); answer(UNNotificationDefaultActionIdentifier) }.linkButtonStyle()
                    }
                    .controlSize(.small)
                    .padding(.top, 3)
                    if model.isExpanded(id) { DecisionSectionsView(sections: DecisionDetail.approval(approval.facts(agentTitle: AgentAttentionCenter.shared.title(of: approval.agent)))).padding(.top, 4) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DecisionChevron(id: id)
            }
        }
    }

    private func answer(_ action: String) {
        AgentAttentionCenter.shared.respond(agent: approval.agent, request: approval.permission, action: action, text: nil)
    }
}
