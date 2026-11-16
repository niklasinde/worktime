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
    private var timer: Timer?
    private var watching: [String: AnyCancellable] = [:]

    init(file: URL = AppPaths.routines) {
        self.file = file
        routines = Routines.settled(Routines.decode(try? Data(contentsOf: file)), now: Date())
    }

    func start() {
        save()
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

    private func tick() {
        let running = Set(routines.filter(isRunning).map(\.id))
        let result = Routines.tick(routines, now: Date(), running: running)
        if result.routines != routines {
            routines = result.routines
            save()
        }
        for id in result.fire { routines.first { $0.id == id }.map(run) }
    }

    /// A fresh session with the routine's prompt. A run already going is left alone.
    private func run(_ routine: Routine) {
        let model = load(routine)
        guard !model.busy, !isRunning(routine) else { return }
        let started = Date()
        model.update(routine: routine)
        model.newSession()
        model.draft = routine.prompt
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
        notify(routine, run: run)
    }

    private func notify(_ routine: Routine, run: RoutineRun) {
        let text = Routines.notification(for: routine, run: run)
        let now = Date()
        let source = NoticeSource(agent: routine.key, workspace: routine.workspace)
        let notice = AgentNotice(id: UUID().uuidString, title: text.title, body: text.body, link: routine.key, source: source, created: now)
        _ = NoticeCenter.shared.handle(NoticeRequest(id: notice.id, action: .notify, notice: notice, cancel: nil, source: source, created: now))
    }

    private func update(_ key: String, _ change: (inout Routine) -> Void) {
        guard let index = routines.firstIndex(where: { $0.key == key }) else { return }
        change(&routines[index])
        models[key]?.update(routine: routines[index])
        save()
    }

    private func save() {
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
        self.routines = routines
        models = [:]
    }
    #endif
}
