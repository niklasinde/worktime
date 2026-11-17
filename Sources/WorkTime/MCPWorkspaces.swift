import Foundation

/// workspaces, create_workspace, update_workspace, create_space, update_space, delete_space and tag_session: the workspace configuration without
/// editing JSON, changed by the running app (it owns the file) through the agent inbox and applied at once.
extension MCPServer {
    static func workspaceTools(sources: NoticeSources = NoticeSources(), workspaces: WorkspaceSource = WorkspaceSource(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        func send(_ action: WorkspaceRequest.Action, args: [String: Any], draft: WorkspaceDraft? = nil, space: String? = nil, spaceDraft: SpaceDraft? = nil,
                  session: String? = nil, ticket: String? = nil, spaces: [String]? = nil) throws -> String {
            let request = WorkspaceRequest(id: UUID().uuidString, action: action, workspace: FilterLogic.text(args, "workspace"), draft: draft, space: space,
                                           spaceDraft: spaceDraft, session: session, ticket: ticket, spaces: spaces, source: sources.source(), created: now())
            return try sources.ask(AgentInbox.encode(request), id: request.id, name: WorkspaceRequests.requestName(request.id), what: "the workspace change").message
        }
        func space(_ args: [String: Any]) throws -> String {
            guard let text = FilterLogic.text(args, "space") else { throw MCPToolError("space is required: its id or name, as workspaces lists them.") }
            return text
        }
        let workspaceField: [String: Any] = ["type": "string", "description": "The workspace id or name. Left out, your own workspace's, or the only one."]
        let fields: [String: [String: Any]] = [
            "name": ["type": "string", "maxLength": WorkspaceRequests.nameLimit, "description": "Shown in the sidebar."],
            "symbol": ["type": "string", "description": "An SF Symbol name, like briefcase.fill."],
            "color": ["type": "string", "enum": Spaces.colors],
            "roots": ["type": "array", "items": ["type": "string"], "maxItems": WorkspaceRequests.listLimit, "description": "Folders (absolute or ~/…) whose agents belong to the workspace. Replaces the list."],
            "github_owners": ["type": "array", "items": ["type": "string"], "maxItems": WorkspaceRequests.listLimit, "description": "GitHub users or organisations whose pull requests belong to it. Replaces the list."],
            "jira_projects": ["type": "array", "items": ["type": "string"], "maxItems": WorkspaceRequests.listLimit, "description": "Jira project keys like PROJ. Replaces the list."],
            "slack": ["type": "boolean", "description": "Whether its Main reads Slack."],
            "extra_files": ["type": "array", "items": ["type": "string"], "maxItems": WorkspaceRequests.listLimit, "description": "Instruction files added after MAIN.md. Replaces the list."],
        ]
        let spaceFields: [String: [String: Any]] = [
            "name": ["type": "string", "maxLength": WorkspaceRequests.nameLimit, "description": "Shown in the sidebar, like Review."],
            "icon": ["type": "string", "description": "An SF Symbol name, like checkmark.seal."],
            "color": ["type": "string", "enum": Spaces.colors],
        ]
        return [
            MCPTool(name: "workspaces",
                    description: "The user's WorkTime workspaces: id, name, folders (roots), GitHub owners, Jira projects, whether Slack is read, extra instruction files and the spaces of each. "
                        + "Look here before changing one.",
                    properties: ["workspace": ["type": "string", "description": "Only this workspace, by id or name."]]) { args in
                WorkspaceRequests.markdown(workspaces.file().workspaces, only: FilterLogic.text(args, "workspace"))
            },
            MCPTool(name: "create_workspace",
                    description: "Creates a workspace with a Main of its own, ready at once without a restart. The user is asked to approve every creation. Checked like Settings > Workspace: "
                        + "a name that is not taken, folders that are absolute or start with ~/, GitHub names, Jira keys.",
                    properties: fields.merging(["id": ["type": "string", "description": "A lower case id; made from the name when left out."]]) { $1 },
                    required: ["name"], readOnly: false) { args in
                try send(.createWorkspace, args: args, draft: try WorkspaceRequests.draft(args))
            },
            MCPTool(name: "update_workspace",
                    description: "Changes a workspace by id or name: only the fields you pass change, and a list replaces the old one. Applied at once. The user is asked to approve every change.",
                    properties: fields.merging(["workspace": workspaceField]) { $1 }, readOnly: false) { args in
                try send(.updateWorkspace, args: args, draft: try WorkspaceRequests.draft(args.filter { $0.key != "id" }))
            },
            MCPTool(name: "create_space",
                    description: "Adds a space (a lane such as Review or Verify) to a workspace. Applied at once. The user is asked to approve every creation.",
                    properties: spaceFields.merging(["workspace": workspaceField]) { $1 }, required: ["name"], readOnly: false) { args in
                try send(.createSpace, args: args, spaceDraft: try WorkspaceRequests.spaceDraft(args))
            },
            MCPTool(name: "update_space",
                    description: "Renames or restyles a space, by the id or name workspaces gave. Only the fields you pass change. The user is asked to approve every change.",
                    properties: spaceFields.merging(["workspace": workspaceField, "space": ["type": "string", "description": "Its id or name."]]) { $1 },
                    required: ["space"], readOnly: false) { args in
                try send(.updateSpace, args: args, space: try space(args), spaceDraft: try WorkspaceRequests.spaceDraft(args))
            },
            MCPTool(name: "delete_space",
                    description: "Removes a space from a workspace; the sessions and routines in it stay and are only untagged. The user is asked to approve.",
                    properties: ["workspace": workspaceField, "space": ["type": "string", "description": "Its id or name."]], required: ["space"], readOnly: false) { args in
                try send(.deleteSpace, args: args, space: try space(args))
            },
            MCPTool(name: "tag_session",
                    description: "Puts a session in spaces, replacing the ones it had (an empty list clears them): session_id, or ticket for every session about that ticket. "
                        + "Not for an assistant, whose spaces come from its role file. The user is asked to approve.",
                    properties: ["session_id": ["type": "string", "description": "A session id from agents_overview."],
                                 "ticket": ["type": "string", "description": "A Jira key like PROJ-123: all its sessions."],
                                 "spaces": ["type": "array", "items": ["type": "string"], "maxItems": WorkspaceRequests.spaceLimit, "description": "Space ids or names of the session's workspace."]],
                    required: ["spaces"], readOnly: false) { args in
                guard let spaces = try WorkspaceRequests.list(args, "spaces") else { throw MCPToolError("spaces is required (an empty list clears them).") }
                let session = FilterLogic.text(args, "session_id")
                var ticket: String?
                if let text = FilterLogic.text(args, "ticket") {
                    guard let key = JiraLogic.issueKey(text) else { throw MCPToolError("ticket must be a Jira key like PROJ-123.") }
                    ticket = key
                }
                guard (session == nil) != (ticket == nil) else { throw MCPToolError("Give exactly one of session_id or ticket.") }
                return try send(.tagSession, args: args, session: session, ticket: ticket, spaces: spaces)
            },
        ]
    }
}
