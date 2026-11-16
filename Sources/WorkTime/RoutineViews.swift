import AppKit
import SwiftUI

/// The workspace's routines in the agent list, under its assistants, with a button to make one.
struct RoutineSection: View {
    let workspace: Workspace
    @ObservedObject var hub: AgentHub
    @ObservedObject private var store = RoutineStore.shared
    @AppStorage(Routines.collapsedKey) private var collapsedWorkspaces = ""
    @State private var editing: RoutineEdit?
    @State private var deleting: Routine?

    private var collapsedIDs: Set<String> { Set(collapsedWorkspaces.split(separator: ",").map(String.init)) }

    var body: some View {
        let routines = store.routines(in: workspace.id), isCollapsed = collapsedIDs.contains(workspace.id)
        header(count: routines.count, isCollapsed: isCollapsed)
        if !isCollapsed {
            ForEach(routines) { routine in
                Button { hub.selected = routine.key } label: { row(routine) }
                    .buttonStyle(.plain)
                    .contextMenu { menu(routine) }
            }
        }
        Color.clear.frame(height: 0)
            .sheet(item: $editing) { edit in RoutineEditorSheet(routine: edit.routine, isNew: edit.isNew) { saved in
                editing = nil
                if let saved { hub.selected = saved.key }
            } }
            .confirmationDialog("Delete \u{201C}\(deleting?.name ?? "")\u{201D}?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
                Button("Delete Routine", role: .destructive) { if let deleting { store.delete(deleting.key) } }
            } message: {
                Text("Removes the routine and stops its schedule. Claude Code keeps the transcripts of its earlier runs.")
            }
    }

    private func header(count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                var ids = collapsedIDs
                if isCollapsed { ids.remove(workspace.id) } else { ids.insert(workspace.id) }
                collapsedWorkspaces = ids.sorted().joined(separator: ",")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text("Routines").font(.caption2.weight(.semibold))
                    Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the routines of \(workspace.name)" : "Hide the routines of \(workspace.name)")
            Spacer()
            Button { editing = RoutineEdit(routine: RoutineEdit.blank(workspace: workspace.id), isNew: true) } label: { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.plain)
                .help("New Routine: a prompt that runs on a schedule while WorkTime is open")
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.top, 2)
    }

    private func row(_ routine: Routine) -> some View {
        let now = Date(), running = store.isRunning(routine)
        return HStack(alignment: .top, spacing: 7) {
            Circle().fill(Self.color(routine)).frame(width: 7, height: 7).padding(.top, 6)
            Image(systemName: "clock.arrow.2.circlepath").font(.callout).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(routine.name).font(.callout).lineLimit(1)
                Text(Routines.detail(routine, now: now)).font(.caption2).foregroundStyle(running ? Color.orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .opacity(routine.enabled ? 1 : 0.55)
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hub.selected == routine.key ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .help(routine.lastRun?.summary ?? routine.prompt)
    }

    static func color(_ routine: Routine) -> Color {
        guard routine.enabled else { return .gray.opacity(0.5) }
        switch routine.lastRun?.status {
        case .running?: return .orange
        case .failed?: return .red
        case .interrupted?: return .yellow
        case .done?, nil: return .green.opacity(0.8)
        }
    }

    @ViewBuilder
    private func menu(_ routine: Routine) -> some View {
        Button("Run Now") { store.runNow(routine.key) }.disabled(store.isRunning(routine))
        Button(routine.enabled ? "Turn Off" : "Turn On") { store.setEnabled(!routine.enabled, for: routine.key) }
        Button("Edit\u{2026}") { editing = RoutineEdit(routine: routine, isNew: false) }
        Divider()
        Button("Delete\u{2026}", role: .destructive) { deleting = routine }
    }
}

struct RoutineEdit: Identifiable {
    let routine: Routine
    let isNew: Bool

    var id: String { routine.id }

    static func blank(workspace: String) -> Routine {
        Routine(id: UUID().uuidString, name: "", prompt: "", workspace: workspace, schedule: RoutineSchedule(kind: .weekdays), created: Date())
    }
}

/// The New Routine and Edit Routine sheet.
struct RoutineEditorSheet: View {
    @State var routine: Routine
    let isNew: Bool
    let done: (Routine?) -> Void
    @State private var problem: String?
    @ObservedObject private var assistants = AssistantStore.shared

    private static let noAssistant = ""
    private static let defaultModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Routine" : "Edit Routine").font(.headline)
            Text("Runs the prompt in a fresh session on the schedule, while WorkTime is open, and notifies you with the answer. "
                 + "Calls that need your approval are refused, since nobody is there to give it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("Name") { TextField("Name", text: $routine.name, prompt: Text("Morning pull request sweep")).textFieldStyle(.roundedBorder).labelsHidden() }
            field("Prompt") {
                TextEditor(text: $routine.prompt)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            }
            field("Run as") {
                HStack {
                    Picker("Run as", selection: assistantBinding) {
                        Text("Agent").tag(Self.noAssistant)
                        ForEach(assistants.entries(routine.workspace), id: \.key) { Text($0.role.name).tag($0.key) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Model", selection: modelBinding) {
                        Text("Default").tag(Self.defaultModel)
                        ForEach(AgentLogic.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            field("Folder") {
                HStack {
                    Text(folderText).lineLimit(1).truncationMode(.head).foregroundStyle(routine.folder == nil ? .secondary : .primary)
                    Spacer()
                    if routine.folder != nil { Button("Reset") { routine.folder = nil }.buttonStyle(.borderless) }
                    Button("Choose\u{2026}", action: chooseFolder)
                }
            }
            field("Schedule") { schedule }
            Toggle("Run a missed run when WorkTime starts", isOn: $routine.runMissed)
                .help("When the app was closed or the Mac asleep at the scheduled time, run once on the next start; otherwise that run is skipped")
            Toggle("On", isOn: $routine.enabled)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var assistantBinding: Binding<String> {
        Binding { routine.assistant ?? Self.noAssistant } set: { routine.assistant = $0.isEmpty ? nil : $0 }
    }

    private var modelBinding: Binding<String> {
        Binding { routine.model ?? Self.defaultModel } set: { routine.model = $0.isEmpty ? nil : $0 }
    }

    private var folderText: String {
        (routine.folder ?? RoutineStore.shared.folder(routine)).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    @ViewBuilder
    private var schedule: some View {
        HStack {
            Picker("Schedule", selection: $routine.schedule.kind) {
                ForEach(RoutineSchedule.Kind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch routine.schedule.kind {
            case .interval:
                Stepper(value: intervalValue, in: 1...999) { Text("\(intervalValue.wrappedValue)").monospacedDigit() }
                Picker("Unit", selection: intervalInHours) {
                    Text("minutes").tag(false)
                    Text("hours").tag(true)
                }
                .labelsHidden()
                .fixedSize()
            case .weekly:
                Picker("Day", selection: $routine.schedule.weekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
            case .daily, .weekdays:
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute).labelsHidden()
            }
            Spacer()
        }
    }

    private var intervalInHours: Binding<Bool> {
        Binding { routine.schedule.minutes >= 60 && routine.schedule.minutes % 60 == 0 } set: { hours in
            let value = intervalValue.wrappedValue
            routine.schedule.minutes = hours ? value * 60 : value
        }
    }

    private var intervalValue: Binding<Int> {
        Binding { intervalInHours.wrappedValue ? routine.schedule.minutes / 60 : routine.schedule.minutes } set: {
            routine.schedule.minutes = intervalInHours.wrappedValue ? $0 * 60 : $0
        }
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(from: DateComponents(hour: routine.schedule.hour, minute: routine.schedule.minute)) ?? Date()
        } set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            routine.schedule.hour = parts.hour ?? 9
            routine.schedule.minute = parts.minute ?? 0
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: RoutineStore.shared.folder(routine))
        if panel.runModal() == .OK, let url = panel.url { routine.folder = url.path }
    }

    private func save() {
        if let found = Routines.problem(name: routine.name, prompt: routine.prompt, schedule: routine.schedule) { return problem = found }
        done(RoutineStore.shared.save(routine))
    }
}

/// A routine's agent on the Main page, loaded the first time it is picked.
struct AgentRoutinePage: View {
    let key: String
    @Binding var listHidden: Bool
    @ObservedObject private var store = RoutineStore.shared

    var body: some View {
        if let model = store.models[key] {
            AgentView(model: model, listHidden: $listHidden)
        } else if store.routine(key) == nil {
            Text("This routine is gone.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: key) { if let routine = store.routine(key) { store.load(routine) } }
        }
    }
}

/// The routine's name, schedule and last run in its header, with Run now and Edit.
struct AgentRoutineHeader: View {
    let routine: Routine
    @ObservedObject private var store = RoutineStore.shared
    @State private var editing: RoutineEdit?

    var body: some View {
        let current = store.routine(routine.key) ?? routine, now = Date()
        Label { Text(current.name).lineLimit(1) } icon: { Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.secondary) }
            .font(.system(size: 15, weight: .medium))
        Text(Routines.detail(current, now: now)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .help(current.nextRun.map { "Next run: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Switched off")
        Button { store.runNow(current.key) } label: { Label("Run now", systemImage: "play.fill") }
            .disabled(store.isRunning(current))
            .help("Start a fresh session with the routine\u{2019}s prompt now")
        Button { editing = RoutineEdit(routine: current, isNew: false) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            .help("Edit the prompt, schedule and what it runs as")
            .sheet(item: $editing) { edit in RoutineEditorSheet(routine: edit.routine, isNew: false) { _ in editing = nil } }
    }
}
