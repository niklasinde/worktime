import Foundation

/// The real paths of one agent's workspace, for the "where things live" block of its system prompt.
struct AgentWhere: Equatable, Sendable {
    var workspace: Workspace
    /// The slug of the assistant this agent is, nil for Main and other agents.
    var roleSlug: String?
    var workspaceFolders = AppPaths.workspaceFolders
    var support = AppPaths.support
    var routines = AppPaths.routines
    var usageLog = AppPaths.usageLog

    static let placeholders = [
        PromptPlaceholder(name: "workspace_id", note: "the workspace's id"),
        PromptPlaceholder(name: "workspace_name", note: "the workspace's name"),
        PromptPlaceholder(name: "main_file", note: "the workspace's MAIN.md"),
        PromptPlaceholder(name: "assistants_folder", note: "the folder of the workspace's assistant files"),
        PromptPlaceholder(name: "role_line", note: "for an assistant, a line with its own role file; empty for others"),
        PromptPlaceholder(name: "prompts_folder", note: "the workspace's Prompts folder"),
        PromptPlaceholder(name: "shared_prompts_folder", note: "the Prompts folder every workspace shares"),
        PromptPlaceholder(name: "data_folder", note: "the app's data folder"),
        PromptPlaceholder(name: "routines_name", note: "the file in the data folder that holds routines and automations"),
        PromptPlaceholder(name: "usage_name", note: "the file in the data folder that each call to Claude is logged in"),
    ]

    static let sampleValues = AgentWhere(workspace: Workspaces.defaults[0], roleSlug: "reviewer",
                                         workspaceFolders: URL(fileURLWithPath: "/Users/sam/Library/Application Support/MeetingRecorder/Workspaces"),
                                         support: URL(fileURLWithPath: "/Users/sam/Library/Application Support/MeetingRecorder"),
                                         routines: URL(fileURLWithPath: "/Users/sam/Library/Application Support/MeetingRecorder/routines.json"),
                                         usageLog: URL(fileURLWithPath: "/Users/sam/Library/Application Support/MeetingRecorder/usage.jsonl")).values

    var values: [String: String] {
        let assistants = AssistantFiles(folder: workspaceFolders)
        let roleLine = roleSlug.map { "\n- Your role: " + assistants.url(workspace.id, slug: $0).path } ?? ""
        return ["workspace_id": workspace.id, "workspace_name": workspace.name,
                "main_file": WorkspaceInstructionFiles(folder: workspaceFolders).url(for: workspace).path,
                "assistants_folder": assistants.folder(workspace.id).path, "role_line": roleLine,
                "prompts_folder": PromptFiles(folder: workspaceFolders).directory(.workspace(workspace.id)).path,
                "shared_prompts_folder": PromptFiles(folder: workspaceFolders).directory(.shared).path,
                "data_folder": support.path, "routines_name": routines.lastPathComponent, "usage_name": usageLog.lastPathComponent]
    }
}
