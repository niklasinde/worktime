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
    @Published private(set) var analyses: [String: Analysis] = [:]
    @Published private(set) var pending: [String: PendingProposal] = [:]
    private var file: URL
    private var stateFile: URL
    private var timer: Timer?
    private var watching: [String: AnyCancellable] = [:]
    private var automationState: AutomationState
    private var automationsWereOn = Automations.enabled
    private let scripts: RoutineScriptFiles
    /// How each running routine's run is done and whether it is the agent's run to compare with the script.
    private var runModes: [String: (mode: RunMode, sampled: Bool)] = [:]
    /// The event each running automation was started for; the ones waiting for it to finish are in the state, so a restart keeps them.
    private var starting: [String: AutomationEvent] = [:]

    enum Analysis: Equatable {
        case analyzing
        case failed(String)
    }

    init(file: URL = AppPaths.routines, stateFile: URL = AppPaths.automationState, scripts: RoutineScriptFiles = RoutineScriptFiles()) {
        self.file = file
        self.stateFile = stateFile
        self.scripts = scripts
        routines = Routines.settled(Routines.decode(try? Data(contentsOf: file)), now: Date())
        automationState = (try? Data(contentsOf: stateFile)).flatMap { AgentInbox.decode(AutomationState.self, from: $0) } ?? AutomationState()
    }

    func start() {
        for routine in routines { pending[routine.key] = scripts.pending(for: routine.id) }
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
            saved.determinism = old.determinism
            saved.analyzed = old.analyzed
            if old.schedule == saved.schedule, old.enabled == saved.enabled { saved.nextRun = old.nextRun ?? saved.nextRun }
            if old.trigger != saved.trigger || old.enabled != saved.enabled { automationState.rebaseline(saved.id) }
            if old.prompt != saved.prompt, var plan = old.determinism {
                plan.needsRecompile = true
                plan.reason = "The prompt changed."
                saved.determinism = plan
            }
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
        scripts.delete(routine.id)
        analyses[key] = nil
        pending[key] = nil
        routines.removeAll { $0.id == routine.id }
        automationState = automationState.pruned(keeping: routines)
        if AgentHub.shared.selected == key { AgentHub.shared.selected = AgentHub.shared.currentMainKey }
        save()
    }

    /// An agent's create_routine, routines, set_routine_enabled or delete_routine, handed over by the MCP server through the agent inbox.
    func handle(_ request: RoutineRequest) -> NoticeReply {
        switch request.action {
        case .analyze: return analysisBrief(request)
        case .compile: return compile(request)
        default: break
        }
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

    // MARK: Deterministic parts

    func scriptSource(_ routine: Routine) -> String? {
        routine.determinism.flatMap { scripts.load(routine.id, version: $0.version) }.map(RoutineScripts.encode)
    }

    func pendingProposal(_ key: String) -> PendingProposal? { pending[key] }

    /// Has the agent look at the routine's last run for the parts a script could do, and keeps its proposal for the user's click. A
    /// run that made no call a script can make is not worth the look.
    func analyze(_ key: String, automatic: Bool = false) {
        guard let routine = routine(key), analyses[key] != .analyzing else { return }
        let digest = Determinism.digest(items: load(routine).items)
        guard Determinism.worthAnalysing(digest) else {
            update(key) { $0.analyzed = Date() }
            if !automatic { analyses[key] = .failed("The last run made no call a script could make. Run it once, then try again.") }
            return
        }
        analyses[key] = .analyzing
        let prompt = Determinism.analysisPrompt(routine: routine, digest: digest, tools: RoutineScriptRunner.infos(RoutineScriptRunner.tools()))
        let fields = Set(routine.trigger?.kind.fields ?? [])
        Task { [weak self] in
            let outcome: Result<DeterminismProposal, NoticeError>
            do { outcome = Determinism.parse(try await RoutineAnalyzer.answer(to: prompt)) } catch { outcome = .failure(NoticeError(error.localizedDescription)) }
            self?.analyzed(key, digest: digest, outcome: outcome, fields: fields, automatic: automatic)
        }
    }

    private func analyzed(_ key: String, digest: RunDigest, outcome: Result<DeterminismProposal, NoticeError>, fields: Set<String>, automatic: Bool) {
        analyses[key] = nil
        update(key) { $0.analyzed = Date() }
        func fail(_ message: String) { if !automatic { analyses[key] = .failed(message) } }
        guard let routine = routine(key) else { return }
        switch outcome {
        case .failure(let error): fail(error.message)
        case .success(let proposal):
            if let problem = Determinism.problem(proposal, fields: fields) { return fail(problem) }
            guard proposal.mode != .none else { return fail(proposal.summary.isEmpty ? "Nothing in this run is worth replacing with a script." : proposal.summary) }
            let waiting = PendingProposal(proposal: proposal, digest: digest, created: Date())
            scripts.savePending(waiting, for: routine.id)
            pending[key] = waiting
            if automatic { announce(routine, body: "Part of this run could be a script instead of the model: \(proposal.summary) Review it from the routine's menu.") }
        }
    }

    /// Saves the proposal's script as the routine's next version and makes it the plan. The user's click, or an agent's approved `compile_routine`.
    @discardableResult
    func compile(_ key: String, proposal: DeterminismProposal, digest: RunDigest?, outputCharacters: Int? = nil) -> NoticeError? {
        guard let routine = routine(key) else { return NoticeError("There is no such routine.") }
        if let problem = Determinism.problem(proposal, fields: Set(routine.trigger?.kind.fields ?? [])) { return NoticeError(problem) }
        guard let script = proposal.script, proposal.mode != .none else { return NoticeError("There is nothing to compile.") }
        let mode: DeterministicPlan.Mode = proposal.mode == .script ? .script : .hybrid
        let saved = digest.map { Determinism.estimatedTokens(mode: mode, digest: $0, outputCharacters: outputCharacters ?? $0.resultCharacters / 4) }
            ?? routine.determinism?.savedTokens ?? 0
        let version: Int
        do { version = try scripts.save(script, for: routine.id) } catch { return NoticeError("The script could not be saved: \(error.localizedDescription)") }
        let plan = Determinism.plan(from: proposal, version: version, savedTokens: saved, keeping: routine.determinism)
        update(key) { $0.determinism = plan }
        scripts.clearPending(for: routine.id)
        pending[key] = nil
        return nil
    }

    /// Back to the agent doing every run; the saved scripts stay in the routine's folder.
    func revertToAI(_ key: String) {
        update(key) { $0.determinism = nil }
    }

    func dismissProposal(_ key: String) {
        guard let routine = routine(key) else { return }
        scripts.clearPending(for: routine.id)
        pending[key] = nil
    }

    /// An agent's analyze_routine: the analysis brief for the routine's last run, for the agent to answer with compile_routine.
    private func analysisBrief(_ request: RoutineRequest) -> NoticeReply {
        func reply(_ ok: Bool, _ message: String) -> NoticeReply { NoticeReply(id: request.id, ok: ok, notice: nil, message: message) }
        guard let routine = RoutineRequests.find(request.routine, in: routines) else { return reply(false, "No routine with id \(request.routine ?? "").") }
        let digest = Determinism.digest(items: load(routine).items)
        guard Determinism.worthAnalysing(digest) else { return reply(false, "The last run of \"\(routine.name)\" made no call a script could make, so there is nothing to look at yet.") }
        let prompt = Determinism.analysisPrompt(routine: routine, digest: digest, tools: RoutineScriptRunner.infos(RoutineScriptRunner.tools()))
        return reply(true, Determinism.briefIntro(routine) + prompt)
    }

    private func compile(_ request: RoutineRequest) -> NoticeReply {
        func reply(_ ok: Bool, _ message: String) -> NoticeReply { NoticeReply(id: request.id, ok: ok, notice: nil, message: message) }
        guard let routine = RoutineRequests.find(request.routine, in: routines) else { return reply(false, "No routine with id \(request.routine ?? "").") }
        guard let compile = request.compile else { return reply(false, "mode and script are required.") }
        switch Determinism.proposal(from: compile) {
        case .failure(let error): return reply(false, error.message)
        case .success(let proposal):
            let digest = Determinism.digest(items: load(routine).items)
            if let error = self.compile(routine.key, proposal: proposal, digest: digest.readCalls > 0 ? digest : nil) { return reply(false, error.message) }
            return reply(true, "\"\(routine.name)\" now runs as a \(proposal.mode.rawValue); the agent does every run again if the script fails. id \(routine.id).")
        }
    }

    private func announce(_ routine: Routine, body: String) {
        let now = Date(), source = NoticeSource(agent: routine.key, workspace: routine.workspace)
        let notice = AgentNotice(id: UUID().uuidString, title: routine.name, body: body, link: routine.key, source: source, created: now)
        _ = NoticeCenter.shared.handle(NoticeRequest(id: notice.id, action: .notify, notice: notice, cancel: nil, source: source, created: now))
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

    /// The automations that have looked at what was there when they were turned on, so what comes after is new.
    var baselinedAutomations: Set<String> { automationState.baselined }

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

    /// The routine's script first when it has one that is trusted, then the agent: a fresh session with the routine's prompt (or the
    /// shorter prompt that takes the script's output), or for an automation the prompt with the event's fields. A run already going is left alone.
    private func run(_ routine: Routine, event: AutomationEvent? = nil) {
        let model = load(routine)
        guard !model.busy, !isRunning(routine) else { return }
        let started = Date()
        let choice = Determinism.choose(routine.determinism, every: Determinism.fullRunEvery())
        guard choice.mode != .ai, let plan = routine.determinism, let script = scripts.load(routine.id, version: plan.version) else {
            return runAgent(routine, event: event, started: started, mode: .ai, sampled: choice.sampled, prompt: nil)
        }
        starting[routine.id] = event
        update(routine.key) { $0.lastRun = RoutineRun(started: started, status: .running, mode: choice.mode) }
        Task { [weak self] in
            let result = await RoutineScriptRunner.run(script, context: event?.fields ?? [:])
            self?.scripted(routine.key, event: event, started: started, plan: plan, result: result)
        }
    }

    private func scripted(_ key: String, event: AutomationEvent?, started: Date, plan: DeterministicPlan, result: ScriptResult) {
        guard let routine = routine(key) else { return }
        var plan = plan
        plan.prompt = event.map { Automations.prompt(plan.prompt ?? "", event: $0) } ?? plan.prompt
        switch Determinism.decide(result, plan: plan) {
        case .script(let output):
            update(key) { $0.determinism = $0.determinism.map { Determinism.counted($0, mode: .script, sampled: false, failure: nil) } }
            finish(key, run: RoutineRun(started: started, finished: Date(), status: .done, summary: output, mode: .script, savedTokens: plan.savedTokens))
        case .hybrid(let prompt):
            runAgent(routine, event: event, started: started, mode: .hybrid, sampled: false, prompt: prompt)
        case .fallBack(let reason):
            update(key) { $0.determinism = $0.determinism.map { Determinism.counted($0, mode: .ai, sampled: false, failure: reason) } }
            runAgent(routine, event: event, started: started, mode: .ai, sampled: false, prompt: nil)
        }
    }

    private func runAgent(_ routine: Routine, event: AutomationEvent?, started: Date, mode: RunMode, sampled: Bool, prompt: String?) {
        let model = load(routine)
        model.update(routine: routine)
        model.newSession()
        model.draft = prompt ?? event.map { Automations.prompt(routine.prompt, event: $0) } ?? routine.prompt
        starting[routine.id] = event
        runModes[routine.id] = (mode, sampled)
        model.send()
        guard model.busy else {
            let items = model.items.isEmpty ? [AgentItem(id: "problem", kind: .error(model.problem ?? "The routine could not start."))] : model.items
            return finish(routine.key, run: Routines.outcome(items: items, started: started, now: Date()))
        }
        update(routine.key) { $0.lastRun = RoutineRun(started: started, status: .running, mode: mode) }
        watching[routine.key] = model.$busy.dropFirst().removeDuplicates().filter { !$0 }.receive(on: DispatchQueue.main).sink { [weak self, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let model else { return }
                self.finish(routine.key, run: Routines.outcome(items: model.items, started: started, now: Date()))
            }
        }
    }

    private func finish(_ key: String, run: RoutineRun) {
        watching[key] = nil
        var run = run
        let info = routine(key).flatMap { runModes.removeValue(forKey: $0.id) }
        if run.mode == nil, let info { run.mode = info.mode }
        if run.mode == .hybrid, let plan = routine(key)?.determinism { run.savedTokens = plan.savedTokens }
        update(key) { $0.lastRun = run }
        guard let routine = routine(key) else { return }
        if let info, run.status == .done, info.mode == .hybrid || info.sampled {
            update(key) { $0.determinism = $0.determinism.map { Determinism.counted($0, mode: info.mode, sampled: info.sampled, failure: nil) } }
        }
        let event = starting.removeValue(forKey: routine.id)
        if info?.sampled == true, run.status == .done { verify(routine, event: event) }
        if run.status == .done, info?.mode == .ai, routine.determinism == nil, routine.analyzed == nil, Determinism.autoAnalyze() { analyze(key, automatic: true) }
        var reminder: String?
        if let event, run.status == .done, routine.followUp?.remind == true, let made = Automations.reminder(for: event) {
            reminder = TodoModel.shared.remind(title: made.title, source: made.source, preset: .noDate)
        }
        notify(routine, run: run, event: event, reminder: reminder)
        if automationsEnabled(), let next = automationState.queued[routine.id]?.first {
            automationState.queued[routine.id]?.removeFirst()
            saveState()
            self.run(routine, event: next)
        }
    }

    /// After a run the agent did to compare, the script is run once too: one that fails needs recompiling.
    private func verify(_ routine: Routine, event: AutomationEvent?) {
        guard let plan = routine.determinism, let script = scripts.load(routine.id, version: plan.version) else { return }
        Task { [weak self] in
            let result = await RoutineScriptRunner.run(script, context: event?.fields ?? [:])
            guard let failure = result.failure else { return }
            self?.update(routine.key) { $0.determinism = $0.determinism.map { Determinism.counted($0, mode: .ai, sampled: false, failure: failure) } }
        }
    }

    /// The notification of a run. An automation that asks makes it carry the question and its two buttons; the others carry the answer.
    private func notify(_ routine: Routine, run: RoutineRun, event: AutomationEvent?, reminder: String? = nil) {
        var question: NoticeAsk?
        if let event, run.status == .done, let ask = routine.followUp?.ask {
            question = AutomationAsks.notice(for: routine, event: event, run: run, ask: ask, reminder: reminder)
        }
        if event != nil, question == nil, routine.followUp?.notify == false { return }
        let text = event.map { event in
            question == nil ? Automations.notification(for: routine, event: event, run: run)
                : AutomationAsks.notification(for: routine, event: event, run: run, ask: routine.followUp?.ask ?? AutomationAsk())
        } ?? Routines.notification(for: routine, run: run)
        let now = Date()
        var source = NoticeSource(agent: routine.key, workspace: routine.workspace)
        if event?.kind.offersReview == true { source.reviewing = true }
        var notice = AgentNotice(id: UUID().uuidString, title: text.title, body: text.body, link: event.flatMap(Automations.noticeLink) ?? routine.key,
                                 source: source, created: now)
        notice.ask = question
        _ = NoticeCenter.shared.handle(NoticeRequest(id: notice.id, action: .notify, notice: notice, cancel: nil, source: source, created: now))
    }

    /// Notes the user's answer to an automation's question, for its row.
    func record(_ answer: AskAnswer, routine id: String) {
        automationState.answers[id] = answer
        saveState()
        objectWillChange.send()
    }

    func lastAnswer(_ routine: Routine) -> AskAnswer? { automationState.answers[routine.id] }

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
