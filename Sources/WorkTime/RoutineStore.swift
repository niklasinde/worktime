import Combine
import Foundation

/// The routines: kept in a file, started on their schedule while the app runs, each in an agent of its own whose sessions
/// (one per run) are its history. Their models are made when first shown or run and live for this run of the app.
@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()
    static let pollInterval: TimeInterval = 30

    @Published private(set) var routines: [Routine]
    @Published private(set) var models: [String: AgentModel] = [:]
    private var file: URL
    private var stateFile: URL
    private var timer: Timer?
    private var watching: [String: AnyCancellable] = [:]
    private var automationState: AutomationState
    private var automationsWereOn = Automations.enabled
    /// The event each running automation was started for; the ones waiting for it to finish are in the state, so a restart keeps them.
    private var starting: [String: AutomationEvent] = [:]

    init(file: URL = AppPaths.routines, stateFile: URL = AppPaths.automationState) {
        self.file = file
        self.stateFile = stateFile
        routines = Routines.settled(Routines.decode(try? Data(contentsOf: file)), now: Date())
        automationState = (try? Data(contentsOf: stateFile)).flatMap { AgentInbox.decode(AutomationState.self, from: $0) } ?? AutomationState()
    }

    func start() {
        save()
        resumeQueued()
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func routine(_ key: String) -> Routine? { routines.first { $0.key == key } }

    func routines(in workspace: String) -> [Routine] {
        routines.filter { $0.workspace == workspace }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isRunning(_ routine: Routine) -> Bool { routine.lastRun?.status == .running }

    /// Names by key, for notifications to say who they come from.
    var titles: [String: String] { Dictionary(routines.map { ($0.key, $0.name) }) { first, _ in first } }

    // MARK: Editing

    /// Adds the routine or replaces the one with its id; a changed one is due next at its schedule's next time.
    @discardableResult
    func save(_ routine: Routine) -> Routine {
        var saved = Routines.armed(routine, now: Date())
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            let old = routines[index]
            saved.lastRun = old.lastRun
            if old.schedule == saved.schedule, old.enabled == saved.enabled { saved.nextRun = old.nextRun ?? saved.nextRun }
            if old.trigger != saved.trigger || old.enabled != saved.enabled { automationState.rebaseline(saved.id) }
            routines[index] = saved
        } else {
            routines.append(saved)
        }
        models[saved.key]?.update(routine: saved)
        save()
        return saved
    }

    func setEnabled(_ enabled: Bool, for key: String) {
        guard var routine = routine(key) else { return }
        routine.enabled = enabled
        save(routine)
    }

    func setModel(_ model: String, for key: String) {
        guard var routine = routine(key), routine.model != model else { return }
        routine.model = model
        save(routine)
    }

    /// Forgets the routine; its agent's sessions stay in Claude Code's own files.
    func delete(_ key: String) {
        guard let routine = routine(key) else { return }
        watching[key] = nil
        models[key]?.stopClient()
        models[key] = nil
        AgentModel.savedSessions[key] = nil
        _ = AgentSessionStore.update(key) { _ in [] }
        routines.removeAll { $0.id == routine.id }
        automationState = automationState.pruned(keeping: routines)
        if AgentHub.shared.selected == key { AgentHub.shared.selected = AgentHub.shared.currentMainKey }
        save()
    }

    /// An agent's create_routine, routines, set_routine_enabled or delete_routine, handed over by the MCP server through the agent inbox.
    func handle(_ request: RoutineRequest) -> NoticeReply {
        let result = RoutineRequests.handle(request, routines: routines, workspaces: WorkspaceStore.shared.workspaces.map(\.id),
                                            assistants: Set(AssistantStore.shared.all.map(\.key)), now: Date())
        switch result.change {
        case .save(let routine): save(routine)
        case .setEnabled(let key, let enabled): setEnabled(enabled, for: key)
        case .delete(let key): delete(key)
        case nil: break
        }
        return result.reply
    }

    // MARK: Agents

    /// The folder a routine works in: its own, its assistant's, or the workspace's.
    func folder(_ routine: Routine) -> String {
        if let folder = routine.folder, !folder.isEmpty { return folder }
        if let entry = routine.assistant.flatMap(AssistantStore.shared.entry) { return AssistantStore.shared.folder(entry) }
        return (WorkspaceStore.shared.workspace(routine.workspace) ?? Workspaces.defaults[0]).defaultFolder()
    }

    /// The routine's agent, made when it is not loaded yet, showing the session of its last run.
    @discardableResult
    func load(_ routine: Routine) -> AgentModel {
        let model = models[routine.key] ?? AgentModel(folder: folder(routine))
        if models[routine.key] == nil {
            model.open(routine: routine, folder: folder(routine))
            models[routine.key] = model
        }
        return model
    }

    func stopAll() { models.values.forEach { $0.stopClient() } }

    // MARK: Running

    func runNow(_ key: String) {
        guard let routine = routine(key) else { return }
        run(routine)
    }

    // MARK: Events

    /// Whether automations are on. Turning them back on starts from what is there again, so nothing that happened meanwhile runs.
    func automationsEnabled() -> Bool {
        let on = Automations.enabled
        guard on != automationsWereOn else { return on }
        automationsWereOn = on
        if on { automationState.rebaselineAll() } else { automationState.queued = [:] }
        saveState()
        return on
    }

    /// The events of one kind the app can see now, once their source has loaded: starts the automations they trigger. With `only` the
    /// events are for that automation alone: its own search found them.
    func ingest(kind: AutomationTrigger.Kind, events: [AutomationEvent], only routine: String? = nil) {
        guard automationsEnabled() else { return }
        let scope = routine.map { id in routines.filter { $0.id == id } } ?? routines
        let plan = Automations.plan(kind: kind, events: events, routines: scope, state: automationState, now: Date())
        guard plan.state != automationState else { return }
        automationState = plan.state
        saveState()
        for firing in plan.fire { routines.first { $0.id == firing.routine }.map { fire($0, event: firing.event) } }
    }

    /// Runs the automation for the event now, or after the run it is in the middle of; a long queue drops the newest.
    func fire(_ routine: Routine, event: AutomationEvent) {
        guard isRunning(routine) || models[routine.key]?.busy == true else { return run(routine, event: event) }
        guard automationState.queued[routine.id, default: []].count < Automations.queueLimit else { return }
        automationState.queued[routine.id, default: []].append(event)
        saveState()
    }

    /// Starts the events that were waiting when the app quit.
    private func resumeQueued() {
        let pending = automationState.queued
        automationState.queued = [:]
        if automationsEnabled() {
            for routine in routines where routine.enabled { pending[routine.id]?.forEach { fire(routine, event: $0) } }
        }
        saveState()
    }

    /// The latest event the automation matched, for trying it out.
    func lastEvent(_ routine: Routine) -> AutomationEvent? { automationState.last[routine.id] }

    func runWithLastEvent(_ key: String) {
        guard let routine = routine(key), let event = lastEvent(routine) else { return }
        fire(routine, event: event)
    }

    private func tick() {
        let running = Set(routines.filter(isRunning).map(\.id))
        let result = Routines.tick(routines, now: Date(), running: running)
        if result.routines != routines {
            routines = result.routines
            save()
        }
        for id in result.fire { routines.first { $0.id == id }.map { run($0) } }
    }

    /// A fresh session with the routine's prompt, or for an automation the prompt with the event's fields. A run already going is left alone.
    private func run(_ routine: Routine, event: AutomationEvent? = nil) {
        let model = load(routine)
        guard !model.busy, !isRunning(routine) else { return }
        let started = Date()
        model.update(routine: routine)
        model.newSession()
        model.draft = event.map { Automations.prompt(routine.prompt, event: $0) } ?? routine.prompt
        starting[routine.id] = event
        model.send()
        guard model.busy else {
            let items = model.items.isEmpty ? [AgentItem(id: "problem", kind: .error(model.problem ?? "The routine could not start."))] : model.items
            return finish(routine.key, run: Routines.outcome(items: items, started: started, now: Date()))
        }
        update(routine.key) { $0.lastRun = RoutineRun(started: started, status: .running) }
        watching[routine.key] = model.$busy.dropFirst().removeDuplicates().filter { !$0 }.receive(on: DispatchQueue.main).sink { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.finish(routine.key, run: Routines.outcome(items: model.items, started: started, now: Date()))
            }
        }
    }

    private func finish(_ key: String, run: RoutineRun) {
        watching[key] = nil
        update(key) { $0.lastRun = run }
        guard let routine = routine(key) else { return }
        let event = starting.removeValue(forKey: routine.id)
        notify(routine, run: run, event: event)
        if let event, run.status == .done, routine.followUp?.remind == true,
           let reminder = Automations.reminder(for: event) {
            TodoModel.shared.remind(title: reminder.title, source: reminder.source, preset: .noDate)
        }
        if automationsEnabled(), let next = automationState.queued[routine.id]?.first {
            automationState.queued[routine.id]?.removeFirst()
            saveState()
            self.run(routine, event: next)
        }
    }

    private func notify(_ routine: Routine, run: RoutineRun, event: AutomationEvent?) {
        if event != nil, routine.followUp?.notify == false { return }
        let text = event.map { Automations.notification(for: routine, event: $0, run: run) } ?? Routines.notification(for: routine, run: run)
        let now = Date()
        var source = NoticeSource(agent: routine.key, workspace: routine.workspace)
        if event?.kind.offersReview == true { source.reviewing = true }
        let notice = AgentNotice(id: UUID().uuidString, title: text.title, body: text.body, link: event.flatMap(Automations.noticeLink) ?? routine.key,
                                 source: source, created: now)
        _ = NoticeCenter.shared.handle(NoticeRequest(id: notice.id, action: .notify, notice: notice, cancel: nil, source: source, created: now))
    }

    private func update(_ key: String, _ change: (inout Routine) -> Void) {
        guard let index = routines.firstIndex(where: { $0.key == key }) else { return }
        change(&routines[index])
        models[key]?.update(routine: routines[index])
        save()
    }

    private func saveState() {
        let data = AgentInbox.encode(automationState), file = stateFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func save() {
        saveState()
        let data = Routines.encode(routines), file = file
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        AgentStateWriter.shared.changed()
    }

    #if DEBUG
    /// Points the store at a file of its own, for the previews.
    func useSample(file: URL, routines: [Routine]) {
        models.values.forEach { $0.stopClient() }
        timer?.invalidate()
        self.file = file
        stateFile = file.deletingLastPathComponent().appendingPathComponent("automation-state.json")
        self.routines = routines
        models = [:]
    }
    #endif
}
