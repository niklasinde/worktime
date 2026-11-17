import AppKit
import SwiftUI

/// The workspace's routines, or with `automations` the ones an event starts, in the agent list under its assistants, with a button to make one.
struct RoutineSection: View {
    let workspace: Workspace
    @ObservedObject var hub: AgentHub
    var automations = false
    @ObservedObject private var store = RoutineStore.shared
    @AppStorage(Routines.collapsedKey) private var collapsedRoutines = ""
    @AppStorage(Routines.automationsCollapsedKey) private var collapsedAutomations = ""
    @State private var editing: RoutineEdit?
    @State private var deleting: Routine?

    private var collapsedWorkspaces: Binding<String> { automations ? $collapsedAutomations : $collapsedRoutines }
    private var collapsedIDs: Set<String> { Set(collapsedWorkspaces.wrappedValue.split(separator: ",").map(String.init)) }
    private var noun: String { automations ? "Automation" : "Routine" }

    var body: some View {
        let routines = store.routines(in: workspace.id).filter { $0.isAutomation == automations }, isCollapsed = collapsedIDs.contains(workspace.id)
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
                Button("Delete \(noun)", role: .destructive) { if let deleting { store.delete(deleting.key) } }
            } message: {
                Text(automations ? "Removes the automation and stops it. Claude Code keeps the transcripts of its earlier runs."
                                 : "Removes the routine and stops its schedule. Claude Code keeps the transcripts of its earlier runs.")
            }
    }

    private func header(count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                var ids = collapsedIDs
                if isCollapsed { ids.remove(workspace.id) } else { ids.insert(workspace.id) }
                collapsedWorkspaces.wrappedValue = ids.sorted().joined(separator: ",")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text("\(noun)s").font(.caption2.weight(.semibold))
                    Text("\(count)").font(.caption2).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show the \(noun.lowercased())s of \(workspace.name)" : "Hide the \(noun.lowercased())s of \(workspace.name)")
            Spacer()
            Button { editing = RoutineEdit(routine: automations ? RoutineEdit.blankAutomation(workspace: workspace.id) : RoutineEdit.blank(workspace: workspace.id), isNew: true) } label: { Image(systemName: "plus").font(.caption) }
                .buttonStyle(.plain)
                .help(automations ? "New Automation: a prompt that runs when something happens, while WorkTime is open"
                                  : "New Routine: a prompt that runs on a schedule while WorkTime is open")
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.top, 2)
    }

    private func row(_ routine: Routine) -> some View {
        let now = Date(), running = store.isRunning(routine)
        return HStack(alignment: .top, spacing: 7) {
            Circle().fill(Self.color(routine)).frame(width: 7, height: 7).padding(.top, 6)
            Image(systemName: routine.isAutomation ? "bolt.fill" : "clock.arrow.2.circlepath").font(.callout).foregroundStyle(.secondary).frame(width: 16)
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
        if routine.isAutomation {
            Button("Run with Last Event") { store.runWithLastEvent(routine.key) }.disabled(store.lastEvent(routine) == nil)
        } else {
            Button("Run Now") { store.runNow(routine.key) }.disabled(store.isRunning(routine))
        }
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

    static func blankAutomation(workspace: String) -> Routine {
        let trigger = AutomationTrigger(kind: .reviewRequested)
        return Routine(id: UUID().uuidString, name: "", prompt: trigger.kind.defaultPrompt, workspace: workspace, schedule: RoutineSchedule(kind: .daily),
                       created: Date(), trigger: trigger, followUp: AutomationFollowUp(notify: true, remind: true))
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
            Text(noun(isNew ? "New " : "Edit ")).font(.headline)
            Text(routine.isAutomation
                 ? "Runs the prompt in a fresh session each time the event happens, while WorkTime is open. Calls that need your approval are refused, "
                    + "and nothing is posted or approved for you: the answer is a draft for you to act on."
                 : "Runs the prompt in a fresh session on the schedule, while WorkTime is open, and notifies you with the answer. "
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
            if routine.isAutomation {
                field("When") { triggerFields }
                field("Then") { followUpFields }
            } else {
                field("Schedule") { schedule }
                Toggle("Run a missed run when WorkTime starts", isOn: $routine.runMissed)
                    .help("When the app was closed or the Mac asleep at the scheduled time, run once on the next start; otherwise that run is skipped")
            }
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

    private func noun(_ prefix: String) -> String { prefix + (routine.isAutomation ? "Automation" : "Routine") }

    private var trigger: Binding<AutomationTrigger> {
        Binding { routine.trigger ?? AutomationTrigger(kind: .reviewRequested) } set: { routine.trigger = $0 }
    }

    private var followUp: Binding<AutomationFollowUp> {
        Binding { routine.followUp ?? AutomationFollowUp() } set: { routine.followUp = $0 }
    }

    private var kindBinding: Binding<AutomationTrigger.Kind> {
        Binding { trigger.wrappedValue.kind } set: { kind in
            let old = trigger.wrappedValue.kind
            if routine.prompt == old.defaultPrompt || routine.prompt.isEmpty { routine.prompt = kind.defaultPrompt }
            trigger.wrappedValue = AutomationTrigger(kind: kind)
        }
    }

    @ViewBuilder
    private var triggerFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Event", selection: kindBinding) {
                ForEach(AutomationTrigger.Source.allCases) { source in
                    Section(source.title) {
                        ForEach(AutomationTrigger.Kind.allCases.filter { $0.source == source }) { Text($0.title).tag($0) }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            ForEach(trigger.wrappedValue.kind.inputs, id: \.self) { input in
                let title = trigger.wrappedValue.kind.title(of: input)
                let required = trigger.wrappedValue.kind.required == input
                TextField(title, text: Binding { trigger.wrappedValue.value(input) } set: { trigger.wrappedValue.set(input, $0) },
                          prompt: Text(title + (input == .jql || input == .pattern ? "" : required ? " (commas for several)" : " (any; commas for several)")))
                    .textFieldStyle(.roundedBorder)
            }
            if trigger.wrappedValue.kind == .slackMessage {
                Toggle("Mentions a pull request", isOn: trigger.needsPullRequest)
            }
            Text("Placeholders in the prompt: " + trigger.wrappedValue.kind.fields.map { "{\($0)}" }.joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = trigger.wrappedValue.kind.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var followUpFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Notify me with the answer", isOn: followUp.notify)
            Toggle("Remind me to follow up", isOn: followUp.remind)
                .help("A reminder linked to the pull request, the ticket or the message, made when the run finishes")
            if routine.trigger?.kind.offersReview == true || routine.trigger?.needsPullRequest == true {
                Text("The notification can open the pull request with Approve or Request changes, which you still confirm on the page.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
        if let found = Routines.problem(name: routine.name, prompt: routine.prompt, schedule: routine.schedule, trigger: routine.trigger) { return problem = found }
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
        Label { Text(current.name).lineLimit(1) } icon: { Image(systemName: current.isAutomation ? "bolt.fill" : "clock.arrow.2.circlepath").foregroundStyle(.secondary) }
            .font(.system(size: 15, weight: .medium))
        Text(Routines.detail(current, now: now)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            .help(current.nextRun.map { "Next run: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Switched off")
        Button { current.isAutomation ? store.runWithLastEvent(current.key) : store.runNow(current.key) } label: {
            Label(current.isAutomation ? "Test with last event" : "Run now", systemImage: "play.fill")
        }
        .disabled(store.isRunning(current) || (current.isAutomation && store.lastEvent(current) == nil))
        .help(current.isAutomation ? "Run the prompt now with the latest event it matched" : "Start a fresh session with the routine\u{2019}s prompt now")
        Button { editing = RoutineEdit(routine: current, isNew: false) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
            .help("Edit the prompt, when it runs and what it runs as")
            .sheet(item: $editing) { edit in RoutineEditorSheet(routine: edit.routine, isNew: false) { _ in editing = nil } }
    }
}
