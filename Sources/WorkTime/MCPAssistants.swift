import Foundation

/// create_assistant, update_assistant, assistants and delete_assistant: the role agents under a workspace's Main, kept as Markdown files
/// by the running app and read and changed through the agent inbox.
extension MCPServer {
    static func assistantTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ action: AssistantRequest.Action, draft: AssistantDraft? = nil, assistant: String? = nil) throws -> String {
            let request = AssistantRequest(id: UUID().uuidString, action: action, draft: draft, assistant: assistant, source: sources.source(), created: now())
            return try sources.ask(AgentInbox.encode(request), id: request.id, name: AssistantRequests.requestName(request.id), what: "the assistant").message
        }
        func assistant(_ args: [String: Any]) throws -> String {
            guard let text = FilterLogic.text(args, "assistant") else { throw MCPToolError("assistant is required: its key or name, as assistants lists them.") }
            return text
        }
        let fields: [String: [String: Any]] = [
            "name": ["type": "string", "maxLength": Assistants.nameLimit, "description": "Shown in the sidebar and used to address it, like Reviewer."],
            "description": ["type": "string", "maxLength": Assistants.summaryLimit, "description": "One line telling Main when to hand work to this assistant."],
            "instructions": ["type": "string", "description": "The assistant's role instructions, in Markdown: how it works and what it must not do."],
            "icon": ["type": "string", "description": "An SF Symbol name, like hammer."],
            "model": ["type": "string", "enum": Assistants.models],
            "permission_mode": ["type": "string", "enum": Assistants.modes, "description": "How it asks for permission; ask when left out."],
            "tools": ["type": "array", "items": ["type": "string"], "description": "WorkTime tools it may call besides the default reading ones, like jira_issue."],
            "chrome": ["type": "boolean", "description": "Its sessions start with Claude in Chrome on, for an assistant that drives a browser; off when left out."],
            "folder": ["type": "string", "description": "Absolute folder, ~/…, or own for a folder of its own; the workspace's folder when left out or empty."],
        ]
        return [
            MCPTool(name: "create_assistant",
                    description: "Creates an assistant in a WorkTime workspace: a role agent under Main with its own instructions, tools and permissions, kept as a "
                        + "Markdown file. The user is asked to approve every creation. It fails when one with that name exists.",
                    properties: fields.merging(["workspace": ["type": "string", "description": "The workspace id; your own when left out."]]) { $1 },
                    required: ["name", "description", "instructions"], readOnly: false) { args in
                try send(.create, draft: try AssistantRequests.draft(args))
            },
            MCPTool(name: "update_assistant", description: "Changes one of the user's WorkTime assistants, by the key or name assistants gave: only the fields you pass "
                        + "change. The user is asked to approve every change.",
                    properties: fields.merging(["assistant": ["type": "string", "description": "Its key or name."]]) { $1 },
                    required: ["assistant"], readOnly: false) { args in
                try send(.update, draft: try AssistantRequests.draft(args), assistant: try assistant(args))
            },
            MCPTool(name: "assistants",
                    description: "The user's WorkTime assistants in every workspace: key, name, when to use it, model, permissions, tools and folder. "
                        + "With assistant (key or name) it also returns that one's instructions.",
                    properties: ["assistant": ["type": "string", "description": "Its key or name."]]) { args in
                try send(.list, assistant: FilterLogic.text(args, "assistant"))
            },
            MCPTool(name: "delete_assistant",
                    description: "Deletes one of the user's WorkTime assistants (its file; its sessions and own folder stay), by the key or name assistants gave. "
                        + "The user is asked to approve.",
                    properties: ["assistant": ["type": "string", "description": "Its key or name."]], required: ["assistant"], readOnly: false) { args in
                try send(.delete, assistant: try assistant(args))
            },
        ]
    }
}
