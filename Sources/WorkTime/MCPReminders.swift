import Foundation

/// add_reminder, reminders and complete_reminder: the reminders WorkTime keeps, read and written by the running app (it owns
/// the file) through the agent inbox.
extension MCPServer {
    static func reminderTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ request: ReminderRequest) throws -> String {
            try sources.ask(AgentInbox.encode(request), id: request.id, name: ReminderLogic.requestName(request.id), what: "the reminder").message
        }
        func request(_ action: ReminderRequest.Action) -> ReminderRequest {
            ReminderRequest(id: UUID().uuidString, action: action, source: sources.source(), created: now())
        }
        return [
            MCPTool(name: "add_reminder",
                    description: "Adds a reminder to the user's WorkTime reminders (shown in the notch bar), for something the user "
                        + "should do later rather than be told now. Give the link of what it is about so the user can open the source "
                        + "from the reminder. An open reminder with the same title and due is returned instead of adding another.",
                    properties: ["title": ["type": "string", "maxLength": NoticeLogic.titleLimit, "description": "What to do."],
                                 "notes": ["type": "string", "maxLength": NoticeLogic.bodyLimit],
                                 "due": ["type": "string",
                                         "description": "ISO 8601 (2026-11-13T09:00, local time without an offset) or HH:mm for today "
                                             + "(tomorrow once past), which also sets an alarm then; a date alone (2026-11-13) is all-day. "
                                             + "At most 30 days ahead."],
                                 "link": ["type": "string",
                                          "description": "The source of the reminder, shown with it and opened from it: a GitHub pull request "
                                              + "(url or owner/repo#number), a Jira key or url, a Slack message link, meeting:<id> "
                                              + "(a meeting's id from recent_meetings), or an https url."],
                                 "priority": ["type": "string", "enum": ReminderPriority.allCases.map(\.rawValue)]],
                    required: ["title"], readOnly: false) { args in
                var add = request(.add)
                switch ReminderLogic.draft(args, now: add.created, timeZone: sources.timeZone) {
                case .success(let draft): add.draft = draft
                case .failure(let error): throw MCPToolError(error.message)
                }
                return try send(add)
            },
            MCPTool(name: "reminders",
                    description: "The user's open WorkTime reminders, due ones soonest first: id, title, due, priority, source and who added it. "
                        + "Optional filters, all combined: due_before, due_after, priority, query, source_kind, source; the answer says which applied.",
                    properties: ["due_before": ["type": "string",
                                                "description": "Only reminders due before this: a date (that day counts), ISO 8601 or HH:mm."],
                                 "due_after": ["type": "string", "description": "Only reminders due at or after this: a date, ISO 8601 or HH:mm."],
                                 "priority": ["type": "string", "enum": ReminderPriority.allCases.map(\.rawValue), "description": "Only this priority."],
                                 "query": ["type": "string", "description": "Only reminders whose title or notes contain this."],
                                 "source_kind": ["type": "string", "enum": ReminderFilter.sourceKinds,
                                                 "description": "Only reminders about this kind of source; none for those without one."],
                                 "source": ["type": "string",
                                            "description": "Only reminders whose source contains this: a Jira key, owner/repo#7, a meeting id or part of a link."]]) { args in
                var list = request(.list)
                list.dueBefore = try FilterLogic.bound(args, "due_before", end: true, now: list.created, timeZone: sources.timeZone)
                list.dueAfter = try FilterLogic.bound(args, "due_after", end: false, now: list.created, timeZone: sources.timeZone)
                list.priority = try FilterLogic.choice(args, "priority", allowed: ReminderPriority.allCases.map(\.rawValue)).flatMap(ReminderPriority.init(rawValue:))
                list.query = FilterLogic.text(args, "query")
                list.sourceKind = try FilterLogic.choice(args, "source_kind", allowed: ReminderFilter.sourceKinds)
                list.sourceQuery = FilterLogic.text(args, "source")
                let applied = FilterLogic.applied(["due_before": FilterLogic.text(args, "due_before"), "due_after": FilterLogic.text(args, "due_after"),
                                                   "priority": list.priority?.rawValue, "query": list.query,
                                                   "source_kind": list.sourceKind, "source": list.sourceQuery])
                return FilterLogic.header(applied) + (try send(list))
            },
            MCPTool(name: "complete_reminder",
                    description: "Marks one of the user's WorkTime reminders as completed, by the id add_reminder or reminders gave.",
                    properties: ["id": ["type": "string"]], required: ["id"], readOnly: false) { args in
                guard let id = FilterLogic.text(args, "id") else { throw MCPToolError("id is required.") }
                var complete = request(.complete)
                complete.reminder = id
                return try send(complete)
            },
        ]
    }
}
