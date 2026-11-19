import Foundation

/// What `create_assistant` and `update_assistant` name: on an update only the fields given change. An empty folder goes back to the workspace's.
struct AssistantDraft: Codable, Equatable, Sendable {
    var name: String?
    var summary: String?
    var instructions: String?
    var icon: String?
    var model: String?
    var permissionMode: String?
    var tools: [String]?
    var chrome: Bool?
    var folder: String?
    var workspace: String?
}

/// What the `--mcp` process hands the app through the agent inbox for the assistant tools; the app answers with a `NoticeReply`.
struct AssistantRequest: Codable, Equatable {
    enum Action: String, Codable { case create, update, list, delete }

    var id: String
    var action: Action
    var draft: AssistantDraft?
    var assistant: String?
    var source: NoticeSource
    var created: Date
}

/// What the app does to its assistant files to answer a request.
enum AssistantChange: Equatable {
    case write(workspace: String, slug: String, text: String)
    case delete(key: String)
}

enum AssistantRequests {
    static func requestName(_ id: String) -> String { "\(id).assistant.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".assistant.json") }

    // MARK: The MCP side

    static func draft(_ args: [String: Any]) throws -> AssistantDraft {
        var tools: [String]?
        switch args["tools"] {
        case nil, is NSNull: break
        case let list as [String]: tools = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case let text as String: tools = JQLFilter.list(text)
        default: throw MCPToolError("tools must be a list of tool names.")
        }
        return AssistantDraft(name: FilterLogic.text(args, "name"), summary: FilterLogic.text(args, "description"),
                              instructions: (args["instructions"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              icon: FilterLogic.text(args, "icon"), model: try FilterLogic.choice(args, "model", allowed: Assistants.modelChoices),
                              permissionMode: try FilterLogic.choice(args, "permission_mode", allowed: Assistants.modes), tools: tools,
                              chrome: args["chrome"] as? Bool,
                              folder: (args["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), workspace: FilterLogic.text(args, "workspace"))
    }

    // MARK: The app's side

    /// What the app does with a request against its assistants: the change to make (nil when there is none) and the answer.
    static func handle(_ request: AssistantRequest, entries: [AssistantEntry], workspaces: [String], tools known: Set<String>, now: Date)
        -> (reply: NoticeReply, change: AssistantChange?) {
        func reply(_ ok: Bool, _ message: String, key: String? = nil, change: AssistantChange? = nil) -> (reply: NoticeReply, change: AssistantChange?) {
            (NoticeReply(id: request.id, ok: ok, notice: key, message: message), change)
        }
        func write(_ base: AssistantRole, applying draft: AssistantDraft, workspace: String, created: Bool)
            -> (reply: NoticeReply, change: AssistantChange?) {
            switch updated(base, with: draft, tools: known) {
            case .failure(let error): return reply(false, error.message)
            case .success(let role):
                let key = Assistants.key(workspace: workspace, slug: role.slug)
                return reply(true, "\(created ? "Created" : "Updated") \(role.name), key \(key).", key: key,
                             change: .write(workspace: workspace, slug: role.slug, text: Assistants.serialise(role)))
            }
        }

        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, "The request is too old.") }
        switch request.action {
        case .list:
            guard let name = request.assistant else { return reply(true, entries.isEmpty ? "No assistants.\n" : entries.map(line).joined(separator: "\n") + "\n") }
            switch Assistants.resolve(name, in: entries) {
            case nil: return reply(false, "No assistant \(name).")
            case .failure(let error)?: return reply(false, error.message)
            case .success(let target)?:
                guard let entry = entries.first(where: { $0.key == target.key }) else { return reply(false, "No assistant \(target.key).") }
                return reply(true, line(entry) + "\n\n" + entry.role.body + "\n", key: entry.key)
            }
        case .create:
            guard let draft = request.draft else { return reply(false, "name and description are required.") }
            let workspace = draft.workspace ?? request.source.workspace ?? Workspaces.defaultID
            guard workspaces.contains(workspace) else { return reply(false, "No workspace \(workspace). Known: \(workspaces.joined(separator: ", ")).") }
            let inWorkspace = entries.filter { $0.workspace == workspace }
            let name = draft.name ?? ""
            if let same = inWorkspace.first(where: { $0.role.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return reply(false, "\(same.role.name) already exists in \(workspace) (key \(same.key)); change it with update_assistant.")
            }
            var role = AssistantRole(slug: Assistants.slug(name), name: name)
            role.slug = TopicAgents.uniqueSlug(role.slug, taken: Set(inWorkspace.map(\.role.slug)))
            return write(role, applying: draft, workspace: workspace, created: true)
        case .update:
            guard let entry = find(request.assistant, in: entries) else { return reply(false, "No assistant \(request.assistant ?? "").") }
            guard entry.role.isUsable else { return reply(false, AssistantError.broken(entry.role.name, entry.role.problems.first?.text ?? "").message) }
            guard let draft = request.draft else { return reply(false, "Nothing to change.") }
            if let name = draft.name, entries.contains(where: { $0.workspace == entry.workspace && $0.key != entry.key && $0.role.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return reply(false, "Another assistant in \(entry.workspace) is already called \(name).")
            }
            return write(entry.role, applying: draft, workspace: entry.workspace, created: false)
        case .delete:
            guard let entry = find(request.assistant, in: entries) else { return reply(false, "No assistant \(request.assistant ?? "").") }
            return reply(true, "Deleted \(entry.role.name); its sessions and its own folder stay.", key: entry.key, change: .delete(key: entry.key))
        }
    }

    /// The role with the draft applied, checked by writing it as a file and reading it back like any role file.
    static func updated(_ role: AssistantRole, with draft: AssistantDraft, tools known: Set<String>) -> Result<AssistantRole, NoticeError> {
        var role = role
        if let name = draft.name { role.name = name }
        if let summary = draft.summary { role.summary = summary }
        if let instructions = draft.instructions { role.body = instructions }
        if let icon = draft.icon { role.icon = icon }
        if let model = draft.model { role.model = model }
        if let mode = draft.permissionMode { role.permissionMode = mode }
        if let chrome = draft.chrome { role.chrome = chrome }
        if let tools = draft.tools {
            if let unknown = tools.first(where: { !$0.hasPrefix("mcp__") && !known.contains($0) }) {
                return .failure(NoticeError("No tool \(unknown). Known: \(known.sorted().joined(separator: ", "))."))
            }
            role.tools = tools
        }
        if let folder = draft.folder {
            guard folder.isEmpty || folder == Assistants.ownFolder || folder.hasPrefix("/") || folder.hasPrefix("~/") else {
                return .failure(NoticeError("folder must be an absolute path, start with ~/ or be \(Assistants.ownFolder), not \(folder)."))
            }
            role.folder = folder.isEmpty ? nil : folder
        }
        if role.body.count > Assistants.bodyLimit { return .failure(NoticeError("instructions can be at most \(Assistants.bodyLimit) characters.")) }
        let parsed = Assistants.parse(slug: role.slug, text: Assistants.serialise(role))
        if let problem = parsed.problems.first { return .failure(NoticeError(problem.message)) }
        return .success(parsed)
    }

    /// By the key, the file name or the role's name.
    static func find(_ text: String?, in entries: [AssistantEntry]) -> AssistantEntry? {
        guard let text, case .success(let target)? = Assistants.resolve(text, in: entries) else { return nil }
        return entries.first { $0.key == target.key }
    }

    static func line(_ entry: AssistantEntry) -> String {
        let role = entry.role
        var parts = ["- key \(entry.key)", role.name, role.summary, "model \(role.model)", "permissions \(role.permissionMode)",
                     "tools " + (role.tools.isEmpty ? "none beyond the default" : role.tools.joined(separator: ", "))]
        if role.chrome { parts.append("Chrome on") }
        if let folder = role.folder { parts.append("folder \(folder)") }
        if !role.isUsable { parts.append("broken: " + (role.problems.first?.text ?? "")) }
        return parts.joined(separator: " \u{00B7} ")
    }
}
