import Foundation

/// create_routine, update_routine, routines, set_routine_enabled and delete_routine: the scheduled agent runs WorkTime keeps, read and changed by
/// the running app (it owns the file and the schedule) through the agent inbox.
extension MCPServer {
    static func routineTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ action: RoutineRequest.Action, draft: RoutineDraft? = nil, patch: RoutinePatch? = nil, routine: String? = nil, enabled: Bool? = nil) throws -> String {
            let request = RoutineRequest(id: UUID().uuidString, action: action, draft: draft, patch: patch, routine: routine, enabled: enabled, source: sources.source(), created: now())
            return try sources.ask(AgentInbox.encode(request), id: request.id, name: RoutineRequests.requestName(request.id), what: "the routine").message
        }
        func routineID(_ args: [String: Any]) throws -> String {
            guard let id = FilterLogic.text(args, "id") else { throw MCPToolError("id is required.") }
            return id
        }
        return [
            MCPTool(name: "create_routine",
                    description: "Creates a routine in WorkTime: a prompt that runs on a schedule in an agent of its own, a fresh session each time, "
                        + "with nobody at the keyboard (a call that needs approval is refused) and a notification when it finishes. It runs only "
                        + "while WorkTime is open. The user is asked to approve every creation. An existing routine with the same name, prompt and "
                        + "schedule is returned instead of adding another.",
                    properties: ["name": ["type": "string", "maxLength": Routines.nameLimit, "description": "Short, shown in the sidebar and the notification."],
                                 "prompt": ["type": "string", "description": "What the routine does each run; it cannot ask questions, so be specific."],
                                 "schedule": ["type": "string", "enum": RoutineRequests.kinds,
                                              "description": "interval needs minutes; daily and weekdays use time; weekly uses weekday and time."],
                                 "minutes": ["type": "integer", "minimum": RoutineSchedule.shortestInterval, "description": "For an interval: minutes between runs."],
                                 "time": ["type": "string", "description": "HH:mm local time of day, 09:00 when left out."],
                                 "weekday": ["type": "string", "description": "For weekly: the day's name, like Monday."],
                                 "workspace": ["type": "string", "description": "The workspace id; the assistant's, else your own, when left out."],
                                 "assistant": ["type": "string", "description": "Run as this assistant (its key, like assistant:work:meeting-follow-up): its instructions, tools and permissions."],
                                 "folder": ["type": "string", "description": "Absolute folder to work in; the assistant's or the workspace's when left out."],
                                 "model": ["type": "string", "enum": AgentLogic.models.compactMap(\.tier), "description": "The assistant's or the default when left out."],
                                 "run_missed": ["type": "boolean", "description": "Run once when the app was closed at the due time; skipped by default."]],
                    required: ["name", "prompt", "schedule"], readOnly: false) { args in
                try send(.create, draft: try RoutineRequests.draft(args))
            },
            MCPTool(name: "update_routine",
                    description: "Changes one of the user's WorkTime routines, by the id create_routine or routines gave: only the fields you pass change. "
                        + "An empty assistant, folder or model resets it. The user is asked to approve every change.",
                    properties: ["id": ["type": "string"],
                                 "name": ["type": "string", "maxLength": Routines.nameLimit],
                                 "prompt": ["type": "string"],
                                 "schedule": ["type": "string", "enum": RoutineRequests.kinds],
                                 "minutes": ["type": "integer", "minimum": RoutineSchedule.shortestInterval, "description": "For an interval: minutes between runs."],
                                 "time": ["type": "string", "description": "HH:mm local time of day."],
                                 "weekday": ["type": "string", "description": "For weekly: the day's name, like Monday."],
                                 "workspace": ["type": "string"],
                                 "assistant": ["type": "string", "description": "An assistant key; empty to run as a plain agent."],
                                 "folder": ["type": "string", "description": "Absolute folder; empty to use the default one."],
                                 "model": ["type": "string", "description": "A model tier; empty for the default."],
                                 "run_missed": ["type": "boolean"],
                                 "enabled": ["type": "boolean"]],
                    required: ["id"], readOnly: false) { args in
                try send(.update, patch: try RoutineRequests.patch(args), routine: try routineID(args))
            },
            MCPTool(name: "routines",
                    description: "The user's WorkTime routines: id, name, schedule, whether on, workspace, assistant and how the last run went.",
                    properties: [:]) { _ in try send(.list) },
            MCPTool(name: "set_routine_enabled",
                    description: "Turns one of the user's WorkTime routines on or off, by the id create_routine or routines gave. The user is asked to approve.",
                    properties: ["id": ["type": "string"], "enabled": ["type": "boolean"]], required: ["id", "enabled"], readOnly: false) { args in
                guard let enabled = try FilterLogic.flag(args, "enabled") else { throw MCPToolError("enabled is required.") }
                return try send(.setEnabled, routine: try routineID(args), enabled: enabled)
            },
            MCPTool(name: "delete_routine",
                    description: "Deletes one of the user's WorkTime routines, by the id create_routine or routines gave. The user is asked to approve.",
                    properties: ["id": ["type": "string"]], required: ["id"], readOnly: false) { args in
                try send(.delete, routine: try routineID(args))
            },
        ]
    }
}
