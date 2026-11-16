import AppKit
import SwiftUI

/// The status of a ticket as a button: its moves are listed in a popover, and one that needs fields asks for them there.
struct JiraStatusButton: View {
    let key: String
    let ticket: JiraTicket
    @ObservedObject var model: JiraPageModel

    var body: some View {
        Button { model.statusPicker = model.statusPicker == key ? nil : key } label: {
            JiraStatusPill(ticket: ticket, chevron: true)
        }
        .buttonStyle(.plain)
        .help("Change the status of \(key)")
        .popover(isPresented: Binding(get: { model.statusPicker == key }, set: { if !$0, model.statusPicker == key { model.statusPicker = nil } }),
                 arrowEdge: .bottom) {
            JiraTransitionPicker(key: key, model: model)
        }
    }
}

struct JiraTransitionPicker: View {
    let key: String
    @ObservedObject var model: JiraPageModel
    @State private var chosen: JiraTransition?
    @State private var values: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chosen { form(chosen) } else { list }
        }
        .padding(10)
        .frame(width: 290)
        .onAppear { model.loadTransitions(key) }
    }

    @ViewBuilder private var list: some View {
        if let error = model.transitionErrors[key] {
            Label(error.message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            Button("Try Again") { model.loadTransitions(key, force: true) }.controlSize(.small)
        } else if let transitions = model.transitions[key] {
            if transitions.isEmpty { Text("Jira offers no move from this status.").font(.callout).foregroundStyle(.secondary) }
            ForEach(transitions) { transition in
                Button { pick(transition) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(transition)).frame(width: 7, height: 7)
                        Text(transition.name)
                        Spacer(minLength: 6)
                        Text(detail(transition)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Fetching the moves\u{2026}").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ transition: JiraTransition) -> Color {
        JiraStyle.color(JiraTickets.stage(JiraTicket(key: key, summary: "", status: transition.status, priority: nil, updated: nil, category: transition.category)))
    }

    private func detail(_ transition: JiraTransition) -> String {
        transition.needsJira ? "in Jira" : !transition.fields.isEmpty ? "asks for more" : transition.status == transition.name ? "" : transition.status
    }

    private func pick(_ transition: JiraTransition) {
        if transition.needsJira {
            model.browseURL(key).map { _ = NSWorkspace.shared.open($0) }
            model.statusPicker = nil
        } else if transition.fields.isEmpty {
            model.move(key, with: transition)
        } else {
            chosen = transition
        }
    }

    private func form(_ transition: JiraTransition) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { chosen = nil } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text("\(transition.name) needs:").font(.callout.weight(.medium))
            ForEach(transition.fields) { field in fieldView(field) }
            HStack {
                Spacer()
                Button("Move to \(transition.status)") { model.move(key, with: transition, values: values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!JiraWrite.missing(transition, values: values).isEmpty)
            }
        }
    }

    @ViewBuilder private func fieldView(_ field: JiraTransition.Field) -> some View {
        switch field.kind {
        case .choice(multiple: false):
            Picker(field.name, selection: Binding(get: { values[field.key]?.first ?? "" }, set: { values[field.key] = $0.isEmpty ? nil : [$0] })) {
                Text("Choose\u{2026}").tag("")
                ForEach(field.options) { Text($0.name).tag($0.id) }
            }
        case .choice(multiple: true):
            VStack(alignment: .leading, spacing: 2) {
                Text(field.name).font(.caption).foregroundStyle(.secondary)
                ForEach(field.options) { option in
                    Toggle(option.name, isOn: Binding(get: { values[field.key]?.contains(option.id) ?? false }, set: { on in
                        var chosen = values[field.key] ?? []
                        chosen.removeAll { $0 == option.id }
                        if on { chosen.append(option.id) }
                        values[field.key] = chosen
                    }))
                }
            }
        case .text:
            TextField(field.name, text: Binding(get: { values[field.key]?.first ?? "" }, set: { values[field.key] = [$0] })).textFieldStyle(.roundedBorder)
        case .unsupported:
            EmptyView()
        }
    }
}

/// Finds a person in Jira as they are typed, to filter by or to assign a ticket to.
struct JiraPersonPicker: View {
    @ObservedObject var model: JiraPageModel
    let issueKey: String?
    let pick: (JiraPerson) -> Void
    @State private var query = ""
    @State private var found: [JiraPerson] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(issueKey == nil ? "Find a person" : "Assign to\u{2026}", text: $query).textFieldStyle(.roundedBorder)
            if found.isEmpty {
                Text(searching ? "Searching\u{2026}" : query.trimmingCharacters(in: .whitespaces).isEmpty ? "Type a name or an email." : "Nobody found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(found) { person in
                Button { pick(person) } label: {
                    Text(person.name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 260)
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                found = []
                return
            }
            searching = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let people = await model.findPeople(text, assignableTo: issueKey)
            guard !Task.isCancelled else { return }
            found = people
            searching = false
        }
    }
}

/// Writes a comment to a ticket; it is posted only when the button is pressed.
struct JiraCommentBox: View {
    let key: String
    @ObservedObject var model: JiraPageModel
    @State private var sending = false

    var body: some View {
        let text = Binding(get: { model.drafts[key] ?? "" }, set: { model.drafts[key] = $0 })
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 180)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            HStack {
                Text("Posts to Jira as you.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Comment") { send(text.wrappedValue) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func send(_ text: String) {
        guard !sending else { return }
        sending = true
        Task {
            _ = await model.postComment(on: key, text: text)
            sending = false
        }
    }
}

/// What the last change said: Jira's refusal, or the move that can be taken back.
struct JiraBanners: View {
    @ObservedObject var model: JiraPageModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(8).background(.quaternary)
            }
            if let undo = model.undo {
                HStack {
                    Text(undo.text).font(.callout)
                    Spacer()
                    if undo.transition != nil { Button("Undo", action: model.undoMove).buttonStyle(.plain).foregroundStyle(Color.accentColor) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.quaternary)
            }
        }
    }
}
