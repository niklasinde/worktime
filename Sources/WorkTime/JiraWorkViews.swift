import SwiftUI

/// What else the app holds about the selected ticket: its reminders, the Slack messages and meetings that name it.
struct JiraLinkedView: View {
    let key: String
    @ObservedObject var model: JiraPageModel
    @ObservedObject private var todo = TodoModel.shared
    @ObservedObject private var slack = SlackModel.shared

    var body: some View {
        let reminders = JiraLinks.reminders(key, in: todo.book.reminders)
        let messages = JiraLinks.slack(key, in: slack.messages)
        let meetings = model.meetingLinks[key] ?? []
        return VStack(alignment: .leading, spacing: 18) {
            if !reminders.isEmpty {
                section("Reminders") { ForEach(reminders) { ReminderRow(reminder: $0, now: Date()) } }
            }
            if !messages.isEmpty {
                section("Slack") {
                    ForEach(messages) { message in
                        row(icon: "bubble.left.fill", title: message.text.replacingOccurrences(of: "\n", with: " "),
                            detail: [message.place, message.author, ClaudePlugin.ago(message.date, now: Date())].compactMap { $0 }.joined(separator: " \u{00B7} ")) {
                            slack.open(message)
                        }
                    }
                }
            }
            if !meetings.isEmpty {
                section("Meetings") {
                    ForEach(meetings) { meeting in
                        row(icon: "person.2.fill", title: meeting.title, detail: GitHubLogic.updatedText(meeting.date, now: Date())) {
                            todo.openMeeting(meeting.id)
                        }
                    }
                }
            }
        }
        .task(id: key) { model.loadMeetingLinks(key) }
    }

    private func row(icon: String, title: String, detail: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Logs time on the ticket as the user, when they press Log Work.
struct JiraWorklogBox: View {
    let key: String
    @ObservedObject var model: JiraPageModel
    @State private var duration = ""
    @State private var comment = ""
    @State private var earlier = false
    @State private var started = Date()
    @State private var logging = false

    var body: some View {
        let seconds = JiraWorklog.seconds(duration)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("1h 30m", text: $duration).textFieldStyle(.roundedBorder).frame(width: 110)
                TextField("What was done (optional)", text: $comment).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Toggle("Started earlier", isOn: $earlier).toggleStyle(.checkbox)
                if earlier { DatePicker("", selection: $started, in: ...Date()).labelsHidden() }
                Spacer()
                if let seconds {
                    Text(JiraWorklog.format(seconds)).font(.caption).foregroundStyle(.secondary)
                } else if !duration.isEmpty {
                    Text("Use 1h 30m, 2d or 45m").font(.caption).foregroundStyle(.red)
                }
                if logging { ProgressView().controlSize(.small) }
                Button("Log Work") { log(seconds) }.disabled(seconds == nil || logging)
            }
        }
        .controlSize(.small)
    }

    private func log(_ seconds: Int?) {
        guard let seconds, !logging else { return }
        logging = true
        Task {
            let done = await model.logWork(on: key, seconds: seconds, started: earlier ? started : Date(), comment: comment)
            logging = false
            guard done else { return }
            duration = ""
            comment = ""
            earlier = false
        }
    }
}
