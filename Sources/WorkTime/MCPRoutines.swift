import Foundation

/// create_routine, update_routine, routines, set_routine_enabled and delete_routine: the scheduled agent runs WorkTime keeps, read and changed by
/// the running app (it owns the file and the schedule) through the agent inbox. The automation tools are the same runs started by an event.
extension MCPServer {
    static func routineTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ action: RoutineRequest.Action, draft: RoutineDraft? = nil, patch: RoutinePatch? = nil, routine: String? = nil, enabled: Bool? = nil, compile: RoutineCompile? = nil) throws -> String {
            let request = RoutineRequest(id: UUID().uuidString, action: action, draft: draft, patch: patch, routine: routine, enabled: enabled, compile: compile,
                                         source: sources.source(), created: now())
            return try sources.ask(AgentInbox.encode(request), id: request.id, name: RoutineRequests.requestName(request.id), what: "the routine").message
        }
        func routineID(_ args: [String: Any]) throws -> String {
            guard let id = FilterLogic.text(args, "id") else { throw MCPToolError("id is required.") }
            return id
        }
        func automationProperties(creating: Bool) -> [String: [String: Any]] {
            ["name": ["type": "string", "maxLength": Routines.nameLimit, "description": "Short, shown in the sidebar and the notification."],
             "event": ["type": "string", "enum": RoutineRequests.triggerKinds,
                       "description": AutomationTrigger.Kind.allCases.map { "\($0.rawValue): \($0.title.prefix(1).lowercased() + $0.title.dropFirst())" }.joined(separator: "; ")
                           + ". Slack and Jira events other than slack_message and jira_assigned are searched every few minutes, only while an automation of the kind is on."],
             "place": ["type": "string", "description": "Slack: the channel (required for slack_channel) or person; GitHub: the repository (required for pr_opened and pr_updated, owner/name or a name the app lists); "
                         + "Jira: the project key. Any of several, separated by commas. Empty for any."],
             "contains": ["type": "string", "description": "Text the message, pull request title, ticket summary or comment contains; any of several, separated by commas. Required for slack_keyword."],
             "status": ["type": "string", "description": "jira_status: the status the ticket moves to; any of several, separated by commas."],
             "from_status": ["type": "string", "description": "jira_status: the status the ticket moves from; any of several, separated by commas."],
             "jql": ["type": "string", "description": "jira_assigned, jira_status and jira_new: a JQL query the ticket has to match too. jira_new needs a place or this."],
             "pattern": ["type": "string", "description": "slack_channel and slack_keyword: a regular expression the message has to match."],
             "needs_pull_request": ["type": "boolean", "description": "slack_message only: the message has to mention a pull request."],
             "prompt": ["type": "string", "description": "What to do for each event. Placeholders: " + AutomationTrigger.Kind.allCases.map { "\($0.rawValue) \u{2192} " + $0.fields.map { "{\($0)}" }.joined(separator: " ") }.joined(separator: "; ")
                         + (creating ? ". A sensible default for the event when left out." : ".")],
             "notify": ["type": "boolean", "description": "Notify the user with the answer; on by default."],
             "remind": ["type": "boolean", "description": "Make a reminder, linked to the pull request, ticket or message, to follow up; off by default."],
             "ask": ["type": "boolean", "description": "Ask the user what to do next, with two buttons on the notification (they work without opening the app): the first starts ask_agent "
                         + "with ask_prompt, the second skips. The run then only triages: it should end with one line, Recommendation: <first button or skip> and a reason, shown on the notification. "
                         + "With it the default prompt is a triage, and the notification and the reminder stay until the user answers. Naming any ask_ field turns it on."],
             "ask_yes": ["type": "string", "description": "The first button, at most \(AutomationAsk.labelLimit) characters; Review it for a pull request, Start it for a ticket."],
             "ask_no": ["type": "string", "description": "The second button; Skip."],
             "ask_agent": ["type": "string", "description": "The assistant the first button starts, by key (like a Reviewer). Empty starts the agent of the pull request the event is about; a ticket needs one."],
             "ask_prompt": ["type": "string", "description": "What the first button sends to it: the event's placeholders plus {recommendation} and {answer} (the triage run's notes). A default for the event when left out. "
                            + "The agent only drafts: it is never allowed to approve, merge or post."],
             "workspace": ["type": "string"],
             "assistant": ["type": "string", "description": "Run as this assistant (its key), like a reviewer: its instructions, tools and permissions."],
             "folder": ["type": "string", "description": "Absolute folder to work in."],
             "model": ["type": "string", "description": "A model tier."],
             "enabled": ["type": "boolean"]]
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
            MCPTool(name: "create_automation",
                    description: "Creates an automation in WorkTime: a prompt that runs in an agent of its own, a fresh session each time, whenever an event happens "
                        + "(a Slack message, a pull request or a Jira ticket: see event), with nobody at the keyboard (a call that needs approval "
                        + "is refused). It runs only while WorkTime is open, once per event, at most \(Automations.runsPerHour) times an hour. When it finishes the "
                        + "user can be notified (the notification about someone else's pull request offers Approve and Request changes, which the user confirms on the page), "
                        + "asked what to do next with two buttons that start an agent such as a Reviewer from the notification (ask), and "
                        + "reminded to decide. The run's answer is a draft; it never approves or posts. The user is asked to approve every creation.",
                    properties: automationProperties(creating: true), required: ["name", "event"], readOnly: false) { args in
                try send(.create, draft: try RoutineRequests.automationDraft(args))
            },
            MCPTool(name: "update_automation",
                    description: "Changes one of the user's WorkTime automations, by the id create_automation or automations gave: only the fields you pass change. "
                        + "An empty place, contains, status, from_status, jql, pattern, assistant, folder, model or ask_agent clears it; ask false turns the question off. The user is asked to approve every change.",
                    properties: automationProperties(creating: false).merging(["id": ["type": "string"]]) { first, _ in first }, required: ["id"], readOnly: false) { args in
                try send(.update, patch: try RoutineRequests.automationPatch(args), routine: try routineID(args))
            },
            MCPTool(name: "automations",
                    description: "The user's WorkTime automations: id, name, what starts each, whether on, workspace, assistant and how the last run went.",
                    properties: [:]) { _ in try send(.listAutomations) },
            MCPTool(name: "delete_automation",
                    description: "Deletes one of the user's WorkTime automations, by the id create_automation or automations gave. The user is asked to approve.",
                    properties: ["id": ["type": "string"]], required: ["id"], readOnly: false) { args in
                try send(.delete, routine: try routineID(args))
            },
            MCPTool(name: "analyze_routine",
                    description: "Looks at the last run of one of the user's WorkTime routines or automations, by id, for the parts a script could do instead of the model "
                        + "(fixed fetches, filters, formatting). The answer is the analysis to carry out and how to answer it with compile_routine. Read only.",
                    properties: ["id": ["type": "string"]], required: ["id"]) { args in
                try send(.analyze, routine: try routineID(args))
            },
            MCPTool(name: "compile_routine",
                    description: "Makes one of the user's WorkTime routines or automations run partly or wholly as a script, by the id routines gave, after analyze_routine. "
                        + "The script is JSON data that can only call read-only tools: {\"steps\": [{\"id\", \"tool\", \"args\", \"keep\", \"drop\", \"limit\", \"expect\"}], \"output\": \"text with {step id}\"}. "
                        + "A script mode's output is the run's answer; a hybrid's goes where the shorter prompt says {data}. A script that fails, or comes back empty, "
                        + "makes the agent do that run. The user is asked to approve every compile, and sees the script.",
                    properties: ["id": ["type": "string"],
                                 "mode": ["type": "string", "enum": ["script", "hybrid"], "description": "script: the whole run is deterministic; hybrid: a script gathers the data and the prompt does the rest."],
                                 "script": ["type": "string", "description": "The script as JSON text."],
                                 "prompt": ["type": "string", "description": "For a hybrid: the shorter prompt, with {data} where the script's output goes."]],
                    required: ["id", "mode", "script"], readOnly: false) { args in
                guard let mode = FilterLogic.text(args, "mode"), let script = FilterLogic.text(args, "script") else { throw MCPToolError("mode and script are required.") }
                return try send(.compile, routine: try routineID(args), compile: RoutineCompile(mode: mode, script: script, prompt: FilterLogic.text(args, "prompt")))
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
