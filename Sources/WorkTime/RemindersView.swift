import SwiftUI

/// The Reminders page: every reminder by when it is due, the meeting action items suggested as reminders, and the resolved ones.
struct RemindersView: View {
    @ObservedObject private var model = TodoModel.shared
    @State private var filter = ReminderPageFilter()
    @State private var draft = ""

    private static let gutter: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView { content.padding(.horizontal, Self.gutter).padding(.bottom, 20) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.reloadMeetings() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reminders").font(.system(size: 20, weight: .medium))
                Spacer()
                Text("\(model.reminders.count)").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                TextField("New reminder", text: $draft).textFieldStyle(.plain).onSubmit(add)
            }
            FlowLayout(spacing: 2) {
                Button("All") { filter.kind = nil }.buttonStyle(PillButtonStyle(selected: filter.kind == nil))
                ForEach(SuggestionLogic.kinds(in: model.reminders + model.completed, suggested: model.suggestions), id: \.self) { kind in
                    Button(kind.title) { filter.kind = kind }.buttonStyle(PillButtonStyle(selected: filter.kind == kind))
                }
            }
            .padding(.leading, -8)
            TextField("Search", text: $filter.query).textFieldStyle(.roundedBorder).controlSize(.small)
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        let now = Date()
        let sections = ReminderLogic.sections(model.reminders.filter(filter.matches), now: now)
        let suggested = model.suggestions.filter(filter.matches)
        let completed = model.completed.filter(filter.matches)
        if sections.isEmpty && suggested.isEmpty && completed.isEmpty && model.dismissed.isEmpty {
            Text(filter.isEmpty ? "No reminders." : "Nothing matches.").foregroundStyle(.secondary).padding(.vertical, 12)
        }
        ForEach(sections, id: \.section) { group in
            heading(group.section.title, count: group.reminders.count, overdue: group.section == .overdue)
            ForEach(group.reminders) { reminder in
                ReminderRow(reminder: reminder, now: now, pickDate: true)
                Divider()
            }
        }
        if !suggested.isEmpty {
            heading("Suggested from meetings", count: suggested.count)
            ForEach(suggested) { item in
                SuggestionRow(item: item, labeled: true)
                Divider()
            }
        }
        ResolvedReminders(completed: completed, dismissed: model.dismissed.filter(filter.matches))
    }

    private func heading(_ text: String, count: Int, overdue: Bool = false) -> some View {
        Text("\(text) \(count)")
            .font(.caption.bold())
            .foregroundStyle(overdue ? Color.red : .secondary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func add() {
        model.add(draft)
        draft = ""
    }
}

extension ReminderSource.Kind {
    var title: String {
        switch self {
        case .githubPR: "Pull requests"
        case .jira: "Jira"
        case .slack: "Slack"
        case .meeting: "Meetings"
        case .url: "Links"
        }
    }
}
