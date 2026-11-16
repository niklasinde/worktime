import SwiftUI

/// What a reminder is about, as a small chip that opens it.
struct SourceChip: View {
    let source: ReminderSource
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: source.icon).font(.system(size: 9))
                Text(source.label).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open \(source.label)")
    }
}

/// "Remind Me About This" for a context menu: the times to offer, then a reminder that links back to `source`.
struct RemindMeMenu: View {
    let title: String
    let source: ReminderSource

    var body: some View {
        Menu("Remind Me About This") {
            ForEach(ReminderPreset.allCases, id: \.self) { preset in
                Button(preset.title) { TodoModel.shared.remind(title: title, source: source, preset: preset) }
            }
        }
    }
}

/// A reminder as a list row, in the notch bar and on the Reminders page: a round checkbox that fills and drops out, the title
/// (edited in place), when it is due, its source chip and the agent that added it.
struct ReminderRow: View {
    static let completionDelay = 1.0
    let reminder: Reminder
    let now: Date
    var pickDate = false
    var onHold: (Bool) -> Void = { _ in }
    @ObservedObject private var model = TodoModel.shared
    @State private var checked = false
    @State private var editing = false
    @State private var edited = ""
    @State private var picking = false
    @FocusState private var focused: Bool

    var body: some View {
        let overdue = ReminderLogic.section(of: reminder, now: now) == .overdue
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) { CheckCircle(checked: checked) }
                .buttonStyle(.plain)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                if editing {
                    TextField("Reminder", text: $edited)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { endEdit(save: true) }
                        .onExitCommand { endEdit(save: false) }
                } else {
                    Text(reminder.title).lineLimit(2).foregroundStyle(checked ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    if let due = reminder.due {
                        Text(ReminderLogic.dueLabel(due, now: now)).foregroundStyle(overdue ? Color.red : .secondary)
                    }
                    if let source = reminder.source { SourceChip(source: source) { model.open(source) } }
                    if let addedBy = reminder.addedBy { Text(addedBy).foregroundStyle(.tertiary).lineLimit(1) }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if pickDate { dateButton }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .opacity(checked ? 0.6 : 1)
        .animation(.easeOut(duration: 0.15), value: checked)
        .transition(.opacity)
        .contextMenu {
            Button("Edit", action: beginEdit)
            Menu("Set Due") {
                ForEach(ReminderPreset.allCases, id: \.self) { preset in Button(preset.title) { model.setDue(reminder.id, preset) } }
            }
            if let source = reminder.source { Button("Open \(source.label)") { model.open(source) } }
            if JiraModel.shared.configured {
                Button("Create Jira Ticket\u{2026}") { JiraPageModel.shared.startTicket(JiraCreate.draft(reminder: reminder, jiraSite: JiraModel.shared.site)) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(reminder.id) }
        }
    }

    private var dateButton: some View {
        Button { picking = true } label: { Image(systemName: "calendar").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .help("Set the due date")
            .popover(isPresented: $picking) {
                DueEditor(due: reminder.due) { due in
                    model.setDue(reminder.id, due)
                    picking = false
                }
            }
    }

    private func toggle() {
        if checked {
            checked = false
            return
        }
        checked = true
        let id = reminder.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay) {
            guard checked else { return }
            model.complete(id)
        }
    }

    private func beginEdit() {
        edited = reminder.title
        editing = true
        onHold(true)
        DispatchQueue.main.async { focused = true }
    }

    private func endEdit(save: Bool) {
        if save { model.rename(reminder.id, to: edited) }
        editing = false
        focused = false
        onHold(false)
    }
}

/// A meeting action item suggested as a reminder: approve it to make it one, or dismiss it for good.
struct SuggestionRow: View {
    let item: MeetingTodo
    var labeled = false
    @ObservedObject private var model = TodoModel.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.task).lineLimit(2)
                Text([item.owner, item.title].compactMap { $0 }.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if labeled {
                Button("Approve") { model.approve(item) }.help("Make it a reminder")
                Button("Dismiss") { model.dismiss(item) }.help("Hide it for good")
            } else {
                Button { model.approve(item) } label: { Image(systemName: "checkmark.circle") }.help("Make it a reminder")
                Button { model.dismiss(item) } label: { Image(systemName: "xmark") }.help("Dismiss")
            }
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .transition(.opacity)
        .contextMenu {
            Button("Approve") { model.approve(item) }
            Menu("Approve and Remind") {
                ForEach(ReminderPreset.allCases.filter { $0 != .noDate }, id: \.self) { preset in
                    Button(preset.title) { model.approve(item, preset: preset) }
                }
            }
            Button("Dismiss") { model.dismiss(item) }
            Divider()
            Button("Open Meeting") { model.openMeeting(item.meeting) }
        }
    }
}

/// The date and time picker behind a reminder's calendar button.
struct DueEditor: View {
    let set: (ReminderDue?) -> Void
    @State private var date: Date
    @State private var allDay: Bool

    init(due: ReminderDue?, set: @escaping (ReminderDue?) -> Void) {
        self.set = set
        _date = State(initialValue: due?.date ?? ReminderLogic.due(.tomorrow, now: Date())?.date ?? Date())
        _allDay = State(initialValue: due?.allDay ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due", selection: $date, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Toggle("All day", isOn: $allDay)
            HStack {
                Button("Clear") { set(nil) }
                Spacer()
                Button("Set") { set(ReminderLogic.due(date, allDay: allDay)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct CheckCircle: View {
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
