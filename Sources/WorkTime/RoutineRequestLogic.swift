import Foundation

/// What `create_routine` asks for, before the app resolves the workspace and checks the rest.
struct RoutineDraft: Codable, Equatable, Sendable {
    var name: String
    var prompt: String
    var schedule: RoutineSchedule
    var workspace: String?
    var assistant: String?
    var folder: String?
    var model: String?
    var runMissed = false
}

/// What the `--mcp` process hands the app through the agent inbox for the routine tools; the app answers with a `NoticeReply`.
struct RoutineRequest: Codable, Equatable {
    enum Action: String, Codable { case create, list, setEnabled, delete }

    var id: String
    var action: Action
    var draft: RoutineDraft?
    var routine: String?
    var enabled: Bool?
    var source: NoticeSource
    var created: Date
}

/// What the app does to its routines to answer a request.
enum RoutineChange: Equatable {
    case save(Routine)
    case setEnabled(key: String, enabled: Bool)
    case delete(key: String)
}

enum RoutineRequests {
    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let kinds = RoutineSchedule.Kind.allCases.map(\.rawValue)

    static func requestName(_ id: String) -> String { "\(id).routine.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".routine.json") }

    // MARK: The MCP side

    static func draft(_ args: [String: Any]) throws -> RoutineDraft {
        guard let name = FilterLogic.text(args, "name") else { throw MCPToolError("name is required.") }
        guard let prompt = FilterLogic.text(args, "prompt") else { throw MCPToolError("prompt is required.") }
        guard let kind = try FilterLogic.choice(args, "schedule", allowed: kinds).flatMap(RoutineSchedule.Kind.init(rawValue:)) else {
            throw MCPToolError("schedule is required: one of \(kinds.joined(separator: ", ")).")
        }
        var schedule = RoutineSchedule(kind: kind)
        if kind == .interval {
            guard let minutes = MCPServer.number(args["minutes"]), minutes == minutes.rounded() else { throw MCPToolError("minutes is required for an interval schedule.") }
            schedule.minutes = Int(minutes)
        }
        if let time = FilterLogic.text(args, "time") {
            guard let clock = clock(time) else { throw MCPToolError("time must be HH:mm, not \(time).") }
            (schedule.hour, schedule.minute) = clock
        }
        if kind == .weekly {
            guard let weekday = try weekday(args) else { throw MCPToolError("weekday is required for a weekly schedule.") }
            schedule.weekday = weekday
        }
        return RoutineDraft(name: name, prompt: prompt, schedule: schedule, workspace: FilterLogic.text(args, "workspace"),
                            assistant: FilterLogic.text(args, "assistant"), folder: FilterLogic.text(args, "folder"),
                            model: FilterLogic.text(args, "model"), runMissed: try FilterLogic.flag(args, "run_missed") ?? false)
    }

    static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// `Calendar`'s weekday number, from a day's name.
    static func weekday(_ args: [String: Any]) throws -> Int? {
        guard let text = FilterLogic.text(args, "weekday") else { return nil }
        guard let index = weekdayNames.firstIndex(where: { $0.hasPrefix(text.lowercased()) && text.count >= 3 }) else {
            throw MCPToolError("weekday must be a day's name like Monday, not \(text).")
        }
        return index + 1
    }

    // MARK: The app's side

    /// What the app does with a request against its routines: the change to make (nil when there is none) and the answer.
    static func handle(_ request: RoutineRequest, routines: [Routine], workspaces: [String], assistants: Set<String>, now: Date,
                       newID: () -> String = { UUID().uuidString }) -> (reply: NoticeReply, change: RoutineChange?) {
        func reply(_ ok: Bool, _ message: String, id: String? = nil, change: RoutineChange? = nil) -> (reply: NoticeReply, change: RoutineChange?) {
            (NoticeReply(id: request.id, ok: ok, notice: id, message: message), change)
        }
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, "The request is too old.") }
        switch request.action {
        case .list:
            guard !routines.isEmpty else { return reply(true, "No routines.\n") }
            return reply(true, routines.map { line($0, now: now) }.joined(separator: "\n") + "\n")
        case .create:
            guard let draft = request.draft else { return reply(false, "name, prompt and schedule are required.") }
            switch routine(from: draft, source: request.source, workspaces: workspaces, assistants: assistants, id: newID(), now: now) {
            case .failure(let error): return reply(false, error.message)
            case .success(let made):
                if let same = routines.first(where: { sameRoutine($0, made) }) {
                    return reply(true, "\"\(same.name)\" already exists, so it was not created again; id \(same.id).", id: same.id)
                }
                return reply(true, "Created \"\(made.name)\", \(made.schedule.label().lowercased()), workspace \(made.workspace); id \(made.id).",
                             id: made.id, change: .save(made))
            }
        case .setEnabled, .delete:
            guard let found = find(request.routine, in: routines) else { return reply(false, "No routine with id \(request.routine ?? "").") }
            if request.action == .delete { return reply(true, "Deleted \"\(found.name)\".", id: found.id, change: .delete(key: found.key)) }
            let enabled = request.enabled ?? true
            return reply(true, "\"\(found.name)\" is now \(enabled ? "on" : "off").", id: found.id, change: .setEnabled(key: found.key, enabled: enabled))
        }
    }

    /// The routine a draft describes, in the workspace it names, else its assistant's, else the asking agent's, else the default one.
    static func routine(from draft: RoutineDraft, source: NoticeSource, workspaces: [String], assistants: Set<String>, id: String, now: Date) -> Result<Routine, NoticeError> {
        if let problem = Routines.problem(name: draft.name, prompt: draft.prompt, schedule: draft.schedule) { return .failure(NoticeError(problem)) }
        let assistant = draft.assistant
        if let assistant, !assistants.contains(assistant) {
            return .failure(NoticeError("No assistant with key \(assistant)." + (assistants.isEmpty ? "" : " Known: \(assistants.sorted().joined(separator: ", "))")))
        }
        let workspace = draft.workspace ?? assistant.flatMap(Assistants.parse(key:))?.workspace ?? source.workspace ?? Workspaces.defaultID
        guard workspaces.contains(workspace) else { return .failure(NoticeError("No workspace \(workspace). Known: \(workspaces.joined(separator: ", ")).")) }
        if let assistant, Assistants.parse(key: assistant)?.workspace != workspace {
            return .failure(NoticeError("\(assistant) belongs to another workspace than \(workspace)."))
        }
        var folder: String?
        if let raw = draft.folder {
            folder = Workspaces.expand(raw)
            guard folder?.hasPrefix("/") == true else { return .failure(NoticeError("folder must be an absolute path or start with ~/, not \(raw).")) }
        }
        var model: String?
        if let raw = draft.model {
            model = AgentLogic.models.first { [$0.id, $0.tier].contains { $0?.caseInsensitiveCompare(raw) == .orderedSame } }?.id
            guard model != nil else { return .failure(NoticeError("model must be one of \(AgentLogic.models.compactMap(\.tier).joined(separator: ", ")), not \(raw).")) }
        }
        let routine = Routine(id: id, name: draft.name, prompt: draft.prompt, workspace: workspace, assistant: assistant, folder: folder, model: model,
                              schedule: draft.schedule, runMissed: draft.runMissed, created: now)
        return .success(Routines.armed(routine, now: now))
    }

    static func sameRoutine(_ one: Routine, _ other: Routine) -> Bool {
        one.workspace == other.workspace && one.prompt == other.prompt && one.name.caseInsensitiveCompare(other.name) == .orderedSame
            && one.schedule == other.schedule
    }

    /// By the id the tools gave; the routine's key works too.
    static func find(_ id: String?, in routines: [Routine]) -> Routine? {
        guard let id else { return nil }
        return routines.first { $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.key.caseInsensitiveCompare(id) == .orderedSame }
    }

    static func line(_ routine: Routine, now: Date) -> String {
        var parts = ["id \(routine.id)", routine.name, routine.schedule.label(), routine.enabled ? "on" : "off", "workspace \(routine.workspace)"]
        if let assistant = routine.assistant { parts.append("assistant \(assistant)") }
        parts.append(lastRunText(routine, now: now))
        return "- " + parts.joined(separator: " \u{00B7} ")
    }

    private static func lastRunText(_ routine: Routine, now: Date) -> String { Routines.lastRunText(routine.lastRun, now: now) }
}
