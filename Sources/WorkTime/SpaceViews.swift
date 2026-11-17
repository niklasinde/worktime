import AppKit
import SwiftUI

/// One chip of a filter row: a title with its count, and a dot when something behind it waits for the user.
struct FilterChip: View {
    let title: String
    var count: Int?
    var icon: String?
    var tint: Color?
    var dot = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).foregroundStyle(tint ?? .secondary) }
                Text(title)
                if let count { Text("\(count)").foregroundStyle(.tertiary).monospacedDigit() }
                if dot { Circle().fill(Color.orange).frame(width: 5, height: 5).help("Something here waits for you") }
            }
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(selected ? (tint ?? Color.accentColor).opacity(0.18) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The top of a workspace in the sidebar: All and a chip for each space with its count.
struct SpaceChipRow: View {
    let spaces: [Space]
    let counts: [String: Int]
    let waiting: Set<String>
    let selected: String?
    let choose: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                FilterChip(title: "All", count: counts[Spaces.all], dot: waiting.contains(Spaces.all), selected: selected == nil) { choose(nil) }
                ForEach(spaces) { space in
                    FilterChip(title: space.name, count: counts[space.id] ?? 0, icon: space.icon, tint: space.tint, dot: waiting.contains(space.id),
                               selected: selected == space.id) { choose(space.id) }
                }
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The spaces something is in, as small icons.
struct SpaceTags: View {
    let ids: [String]?
    let spaces: [Space]

    var body: some View {
        let shown = spaces.filter { ids?.contains($0.id) == true }
        if !shown.isEmpty {
            HStack(spacing: 3) {
                ForEach(shown) { space in
                    Image(systemName: space.icon).font(.system(size: 9)).foregroundStyle(space.tint).help(space.name)
                }
            }
        }
    }
}

/// The spaces of a session or ticket group in its context menu: tick the ones it is in, or send it to one.
struct SpaceMenus: View {
    let states: [AgentState]
    let spaces: [Space]
    var subject: SessionSubject?
    var workspace: String
    @ObservedObject private var store = WorkspaceStore.shared
    @ObservedObject private var assistants = AssistantStore.shared

    var body: some View {
        if !spaces.isEmpty, !states.isEmpty {
            Divider()
            Menu("Spaces") {
                ForEach(spaces) { space in
                    Toggle(isOn: Binding { states.allSatisfy { Spaces.contains($0, space: space.id) } } set: { on in
                        for state in states { store.setSpaces(on ? Spaces.adding(space.id, to: state.spaces ?? []) : (state.spaces ?? []).filter { $0 != space.id }, for: state.key) }
                    }) { Label(space.name, systemImage: space.icon) }
                }
            }
            Menu("Send to") {
                ForEach(spaces) { space in
                    Button { SpaceHandoffCenter.shared.start(states: states, to: space, subject: subject, workspace: workspace) } label: {
                        Label(space.name, systemImage: space.icon)
                    }
                }
            }
        }
    }
}

/// The handoff the user is confirming; set from the agents list or a notch row, shown by the Main page.
@MainActor
final class SpaceHandoffCenter: ObservableObject {
    static let shared = SpaceHandoffCenter()
    @Published var pending: SpaceHandoff?

    func start(states: [AgentState], to space: Space, subject: SessionSubject?, workspace: String) {
        pending = Spaces.handoff(states: states, to: space, subject: subject, entries: AssistantStore.shared.entries(workspace))
        AgentHub.shared.show()
    }
}

/// Send to a space: adds the tag, and optionally starts the next assistant on the same ticket or pull request with a prompt to edit.
struct SpaceHandoffSheet: View {
    let handoff: SpaceHandoff
    let done: () -> Void
    @State private var start = true
    @State private var prompt: String

    init(handoff: SpaceHandoff, done: @escaping () -> Void) {
        self.handoff = handoff
        self.done = done
        _prompt = State(initialValue: handoff.prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Send to \(handoff.space.name)", systemImage: handoff.space.icon).font(.headline).foregroundStyle(handoff.space.tint)
            Text("Puts \(handoff.subject?.label ?? "it") in the \(handoff.space.name) space, next to the spaces it is in.")
                .font(.callout).foregroundStyle(.secondary)
            if let assistant = handoff.assistant {
                Toggle("and start \(assistant.role.name) on it", isOn: $start)
                if start {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 130)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
                    Text("Goes through the same path as Main\u{2019}s send_to_agent: you are asked when \(assistant.role.name) already has a session for it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(start && handoff.assistant != nil ? "Send" : "Move", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(start && handoff.assistant != nil && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        WorkspaceStore.shared.add(space: handoff.space.id, to: handoff.keys)
        if start, let assistant = handoff.assistant {
            let handoff = handoff, text = prompt
            Task { @MainActor in
                let reply = await AgentInboxWatcher.send(text, to: assistant.key, ticket: handoff.subject?.ticket, pr: handoff.subject?.pullRequest,
                                                         origin: "Sent to \(handoff.space.name)", space: handoff.space.id)
                if reply.status == .rejected {
                    let alert = NSAlert()
                    alert.messageText = "\(assistant.role.name) was not started"
                    alert.informativeText = reply.message
                    alert.runModal()
                }
            }
        }
        done()
    }
}

/// The space chips and the context menu of a decision row, for the agent that raised it.
struct SpaceDecisionAccessory: View {
    let agent: String?
    @ObservedObject private var store = WorkspaceStore.shared
    @ObservedObject private var writer = AgentStateWriter.shared

    private var state: AgentState? { agent.flatMap { key in writer.states().first { $0.key == key } } }

    var body: some View {
        if let state, !store.spaces(of: state.workspace).isEmpty {
            SpaceTags(ids: state.spaces, spaces: store.spaces(of: state.workspace))
        }
    }
}

extension View {
    /// "Send to" a space on a row that belongs to an agent, when its workspace has spaces.
    func spaceContextMenu(agent: String?) -> some View {
        contextMenu { SpaceDecisionMenu(agent: agent) }
    }
}

private struct SpaceDecisionMenu: View {
    let agent: String?
    @ObservedObject private var store = WorkspaceStore.shared

    var body: some View {
        if let state = agent.flatMap({ key in AgentStateWriter.shared.states().first { $0.key == key } }), !store.spaces(of: state.workspace).isEmpty {
            let workspace = state.workspace ?? Workspaces.defaultID
            let subject = TicketGrouping.subject(of: state, projects: Set(store.workspace(workspace)?.jiraProjects.map { $0.uppercased() } ?? []))
            Menu("Send to") {
                ForEach(store.spaces(of: workspace)) { space in
                    Button { SpaceHandoffCenter.shared.start(states: [state], to: space, subject: subject, workspace: workspace) } label: {
                        Label(space.name, systemImage: space.icon)
                    }
                }
            }
        }
    }
}

// MARK: Settings

/// Settings → Workspace: the spaces of a workspace, to add, rename, recolour, reorder and remove.
struct SpacesEditor: View {
    let workspace: Workspace
    @ObservedObject var store: WorkspaceStore

    private var spaces: [Space] { store.workspace(workspace.id)?.spaces ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Spaces")
                Text(spaces.isEmpty ? "none: the sidebar is not divided" : "lanes that divide the sidebar and the work").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { add() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add a space")
            }
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in row(space, index: index) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row(_ space: Space, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: space.icon).foregroundStyle(space.tint).frame(width: 18)
            TextField("Name", text: Binding { space.name } set: { value in change(space.id) { $0.name = value } }).textFieldStyle(.roundedBorder)
            TextField("Symbol", text: Binding { space.icon } set: { value in change(space.id) { $0.icon = value } }).textFieldStyle(.roundedBorder).frame(width: 130)
            Picker("Colour", selection: Binding { space.color } set: { value in change(space.id) { $0.color = value } }) {
                ForEach(Spaces.colors, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(index == 0).help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(index == spaces.count - 1).help("Move down")
            Button { store.removeSpace(space.id, from: workspace.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                .help("Remove the space; what is in it stays and is only untagged")
        }
    }

    private func add() {
        change { workspace in
            let id = Spaces.id(for: "Space", taken: workspace.spaces.map(\.id))
            workspace.spaces.append(Space(id: id, name: "Space", icon: Spaces.defaultIcon, color: Spaces.defaultColor))
        }
    }

    private func move(_ index: Int, by step: Int) {
        change { $0.spaces.move(fromOffsets: IndexSet(integer: index), toOffset: step > 0 ? index + 2 : index - 1) }
    }

    private func change(_ id: String, _ edit: @escaping (inout Space) -> Void) {
        change { workspace in
            if let index = workspace.spaces.firstIndex(where: { $0.id == id }) { edit(&workspace.spaces[index]) }
        }
    }

    private func change(_ edit: (inout Workspace) -> Void) {
        var updated = store.workspace(workspace.id) ?? workspace
        edit(&updated)
        store.update(updated)
    }
}

/// The spaces a routine or automation belongs to, ticked in its editor.
struct SpaceToggles: View {
    let spaces: [Space]
    @Binding var ids: [String]?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(spaces) { space in
                FilterChip(title: space.name, icon: space.icon, tint: space.tint, selected: ids?.contains(space.id) == true) {
                    let next = Spaces.toggling(space.id, in: ids ?? [])
                    ids = next.isEmpty ? nil : next
                }
            }
            Spacer()
        }
    }
}
