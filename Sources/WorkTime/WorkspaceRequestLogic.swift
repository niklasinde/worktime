import Foundation

/// The fields of a workspace the tools can set; on an update only the ones given change, and a list replaces the old one.
struct WorkspaceDraft: Codable, Equatable {
    var id: String?
    var name: String?
    var symbol: String?
    var color: String?
    var roots: [String]?
    var githubOwners: [String]?
    var jiraProjects: [String]?
    var slack: Bool?
    var extraFiles: [String]?
}

struct SpaceDraft: Codable, Equatable {
    var name: String?
    var icon: String?
    var color: String?
}

/// What the `--mcp` process hands the app through the agent inbox for the workspace tools; the app answers with a `NoticeReply`.
struct WorkspaceRequest: Codable, Equatable {
    enum Action: String, Codable { case createWorkspace, updateWorkspace, createSpace, updateSpace, deleteSpace, tagSession }

    var id: String
    var action: Action
    var workspace: String?
    var draft: WorkspaceDraft?
    var space: String?
    var spaceDraft: SpaceDraft?
    var session: String?
    var ticket: String?
    var spaces: [String]?
    var source: NoticeSource
    var created: Date
}

/// What the app does to its workspaces to answer a request.
enum WorkspaceChange: Equatable {
    case create(Workspace)
    case update(Workspace)
    case removeSpace(id: String, workspace: String)
    case tag(keys: [String], spaces: [String])
}

enum WorkspaceRequests {
    static let nameLimit = 40
    static let workspaceLimit = 12
    static let spaceLimit = 12
    static let listLimit = 20
    static let defaultSymbol = "folder.fill"

    static func requestName(_ id: String) -> String { "\(id).workspace.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".workspace.json") }

    // MARK: The MCP side

    static func list(_ args: [String: Any], _ name: String) throws -> [String]? {
        switch args[name] {
        case nil, is NSNull: return nil
        case let items as [String]: return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        case let text as String: return JQLFilter.list(text)
        default: throw MCPToolError("\(name) must be a list of strings.")
        }
    }

    static func draft(_ args: [String: Any]) throws -> WorkspaceDraft {
        WorkspaceDraft(id: FilterLogic.text(args, "id"), name: FilterLogic.text(args, "name"), symbol: FilterLogic.text(args, "symbol"),
                       color: try FilterLogic.choice(args, "color", allowed: Spaces.colors), roots: try list(args, "roots"),
                       githubOwners: try list(args, "github_owners"), jiraProjects: try list(args, "jira_projects"), slack: try FilterLogic.flag(args, "slack"),
                       extraFiles: try list(args, "extra_files"))
    }

    static func spaceDraft(_ args: [String: Any]) throws -> SpaceDraft {
        SpaceDraft(name: FilterLogic.text(args, "name"), icon: FilterLogic.text(args, "icon"), color: try FilterLogic.choice(args, "color", allowed: Spaces.colors))
    }

    // MARK: Checks

    private static func problem(_ text: String) -> NoticeError { NoticeError(text) }

    static func checkName(_ name: String) -> NoticeError? {
        guard !name.isEmpty else { return problem("name is empty.") }
        guard name.count <= nameLimit else { return problem("name is \(name.count) characters; the limit is \(nameLimit).") }
        return nil
    }

    static func checkSymbol(_ symbol: String) -> NoticeError? {
        symbol.wholeMatch(of: #/[a-z0-9][a-z0-9.]{0,39}/#) == nil ? problem("symbol must be an SF Symbol name like briefcase.fill, not \(symbol).") : nil
    }

    static func checkPath(_ path: String, name: String) -> NoticeError? {
        path == "~" || path.hasPrefix("/") || path.hasPrefix("~/") ? nil : problem("\(name) must be absolute paths or start with ~/, not \(path).")
    }

    /// The draft's lists checked and cleaned: paths kept as typed, owners as given, Jira projects upper case, none twice.
    static func apply(_ draft: WorkspaceDraft, to workspace: Workspace) -> Result<Workspace, NoticeError> {
        var workspace = workspace
        if let name = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let error = checkName(name) { return .failure(error) }
            workspace.name = name
        }
        if let symbol = draft.symbol {
            if let error = checkSymbol(symbol) { return .failure(error) }
            workspace.symbol = symbol
        }
        if let color = draft.color { workspace.color = color }
        func unique(_ items: [String]) -> [String] { items.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        if let roots = draft.roots {
            if let bad = roots.compactMap({ checkPath($0, name: "roots") }).first { return .failure(bad) }
            workspace.roots = unique(roots.map { $0 == "/" ? $0 : $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
        }
        if let owners = draft.githubOwners {
            if let bad = owners.first(where: { $0.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]{0,38}/#) == nil }) {
                return .failure(problem("github_owners must be GitHub user or organisation names, not \(bad)."))
            }
            workspace.githubOwners = unique(owners)
        }
        if let projects = draft.jiraProjects {
            let keys = projects.map { $0.uppercased() }
            if let bad = keys.first(where: { $0.wholeMatch(of: #/[A-Z][A-Z0-9_]{1,9}/#) == nil }) {
                return .failure(problem("jira_projects must be project keys like PROJ, not \(bad)."))
            }
            workspace.jiraProjects = unique(keys)
        }
        if let slack = draft.slack { workspace.slack = slack ? workspace.name : nil }
        if let files = draft.extraFiles {
            if let bad = files.compactMap({ checkPath($0, name: "extra_files") }).first { return .failure(bad) }
            workspace.extraFiles = unique(files)
        }
        return .success(workspace)
    }

    /// Roots another workspace already has, which makes the assignment of an agent in them ambiguous.
    static func sharedRoots(_ workspace: Workspace, in others: [Workspace], home: String = NSHomeDirectory()) -> [String] {
        let mine = Set(workspace.roots.map { Workspaces.expand($0, home: home) })
        return others.filter { $0.id != workspace.id }.flatMap(\.roots).map { Workspaces.expand($0, home: home) }.filter(mine.contains)
    }

    // MARK: The app's side

    static func handle(_ request: WorkspaceRequest, file: WorkspaceFile, agents: [AgentState], now: Date, home: String = NSHomeDirectory())
        -> (reply: NoticeReply, change: WorkspaceChange?) {
        func reply(_ ok: Bool, _ message: String, key: String? = nil, change: WorkspaceChange? = nil) -> (reply: NoticeReply, change: WorkspaceChange?) {
            (NoticeReply(id: request.id, ok: ok, notice: key, message: message), change)
        }
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, "The request is too old.") }
        let workspaces = file.workspaces
        func target() -> Result<Workspace, AgentInboxError> {
            AgentReports.target(argument: request.workspace, caller: request.source.workspace ?? (workspaces.count == 1 ? workspaces[0].id : nil), in: workspaces)
        }
        switch request.action {
        case .createWorkspace:
            guard let draft = request.draft, let name = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return reply(false, "name is required.") }
            guard workspaces.count < workspaceLimit else { return reply(false, "WorkTime has \(workspaces.count) workspaces; the limit is \(workspaceLimit).") }
            if let error = checkName(name) { return reply(false, error.message) }
            if workspaces.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.caseInsensitiveCompare(name) == .orderedSame }) {
                return reply(false, "A workspace called \(name) exists; change it with update_workspace.")
            }
            var id = draft.id?.lowercased() ?? TopicAgents.uniqueSlug(name, taken: Set(workspaces.map(\.id)))
            if draft.id != nil {
                guard id.wholeMatch(of: #/[a-z0-9][a-z0-9-]{0,39}/#) != nil else { return reply(false, "id must be lower case letters, digits and dashes, not \(id).") }
                guard !workspaces.contains(where: { $0.id == id }) else { return reply(false, "A workspace with id \(id) exists.") }
            }
            if id.isEmpty { id = "workspace" }
            let base = Workspace(id: id, name: name, symbol: defaultSymbol, color: Spaces.defaultColor, roots: [], githubOwners: [], jiraProjects: [], slack: nil, extraFiles: [])
            switch apply(draft, to: base) {
            case .failure(let error): return reply(false, error.message)
            case .success(let made):
                return reply(true, "Created the workspace \(made.name), id \(made.id); its Main is ready now." + overlap(made, workspaces, home: home), key: made.id, change: .create(made))
            }
        case .updateWorkspace:
            let current: Workspace
            switch target() {
            case .success(let found): current = found
            case .failure(let error): return reply(false, error.message)
            }
            guard let draft = request.draft else { return reply(false, "Nothing to change.") }
            if let name = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines), workspaces.contains(where: { $0.id != current.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return reply(false, "Another workspace is already called \(name).")
            }
            switch apply(draft, to: current) {
            case .failure(let error): return reply(false, error.message)
            case .success(let changed): return reply(true, "Updated \(changed.name)." + overlap(changed, workspaces, home: home), key: changed.id, change: .update(changed))
            }
        case .createSpace, .updateSpace, .deleteSpace:
            let current: Workspace
            switch target() {
            case .success(let found): current = found
            case .failure(let error): return reply(false, error.message)
            }
            return handleSpace(request, in: current, reply: reply)
        case .tagSession:
            guard let ids = request.spaces else { return reply(false, "spaces is required (an empty list clears them).") }
            let live = agents.filter { $0.archived != true && !Workspaces.isMainKey($0.key) }
            let found: [AgentState]
            if let session = request.session { found = live.filter { $0.sessionID == session } } else if let ticket = request.ticket {
                found = live.filter { AgentFilter.about($0, ticket: ticket) }
            } else { return reply(false, "session_id or ticket is required.") }
            guard !found.isEmpty else { return reply(false, "No session found for \(request.session ?? request.ticket ?? "") in agents_overview.") }
            if let assistant = found.first(where: \.isAssistant) { return reply(false, "\(assistant.title) is an assistant; its spaces come from its role file.") }
            let workspace = Workspaces.workspace(found[0].workspace, in: workspaces)
            var resolved: [String] = []
            for text in ids {
                switch Spaces.resolve(text, in: workspace?.spaces ?? []) {
                case .success(let space): resolved = Spaces.adding(space.id, to: resolved)
                case .failure(let error): return reply(false, error.message)
                }
            }
            let label = resolved.isEmpty ? "no spaces" : Spaces.line(resolved, in: workspace?.spaces ?? []) ?? ""
            return reply(true, "Tagged \(found.count) session\(found.count == 1 ? "" : "s") with \(label).", change: .tag(keys: found.map(\.key), spaces: resolved))
        }
    }

    private static func overlap(_ workspace: Workspace, _ others: [Workspace], home: String) -> String {
        let shared = sharedRoots(workspace, in: others, home: home)
        return shared.isEmpty ? "" : " Note: " + shared.joined(separator: ", ") + " is also a folder of another workspace, so agents there go to whichever has the longer folder."
    }

    private static func handleSpace(_ request: WorkspaceRequest, in workspace: Workspace,
                                    reply: (Bool, String, String?, WorkspaceChange?) -> (reply: NoticeReply, change: WorkspaceChange?))
        -> (reply: NoticeReply, change: WorkspaceChange?) {
        func fail(_ message: String) -> (reply: NoticeReply, change: WorkspaceChange?) { reply(false, message, nil, nil) }
        var updated = workspace
        let draft = request.spaceDraft ?? SpaceDraft()
        func check(_ draft: SpaceDraft, except id: String?) -> String? {
            if let name = draft.name {
                if let error = checkName(name) { return error.message }
                if workspace.spaces.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return "A space called \(name) exists in \(workspace.name)." }
            }
            return draft.icon.flatMap(checkSymbol)?.message
        }
        switch request.action {
        case .createSpace:
            guard let name = draft.name else { return fail("name is required.") }
            guard workspace.spaces.count < spaceLimit else { return fail("\(workspace.name) has \(workspace.spaces.count) spaces; the limit is \(spaceLimit).") }
            if let problem = check(draft, except: nil) { return fail(problem) }
            let space = Space(id: Spaces.id(for: name, taken: workspace.spaces.map(\.id)), name: name, icon: draft.icon ?? Spaces.defaultIcon, color: draft.color ?? Spaces.defaultColor)
            updated.spaces.append(space)
            return reply(true, "Created the space \(name) in \(workspace.name), id \(space.id).", space.id, .update(updated))
        case .updateSpace:
            guard let text = request.space else { return fail("space is required.") }
            switch Spaces.resolve(text, in: workspace.spaces) {
            case .failure(let error): return fail(error.message)
            case .success(let found):
                if let problem = check(draft, except: found.id) { return fail(problem) }
                guard let index = updated.spaces.firstIndex(where: { $0.id == found.id }) else { return fail("No space \(text).") }
                if let name = draft.name { updated.spaces[index].name = name }
                if let icon = draft.icon { updated.spaces[index].icon = icon }
                if let color = draft.color { updated.spaces[index].color = color }
                return reply(true, "Updated the space \(updated.spaces[index].name).", found.id, .update(updated))
            }
        default:
            guard let text = request.space else { return fail("space is required.") }
            switch Spaces.resolve(text, in: workspace.spaces) {
            case .failure(let error): return fail(error.message)
            case .success(let found):
                return reply(true, "Deleted the space \(found.name); what was in it stays and is only untagged.", found.id, .removeSpace(id: found.id, workspace: workspace.id))
            }
        }
    }

    // MARK: Reading

    static func line(_ workspace: Workspace) -> String {
        var lines = ["- **\(workspace.name)** \u{00B7} id \(workspace.id) \u{00B7} \(workspace.symbol) \u{00B7} \(workspace.color)"]
        lines.append("  folders: " + (workspace.roots.isEmpty ? "none" : workspace.roots.joined(separator: ", ")))
        lines.append("  owners (GitHub): " + (workspace.githubOwners.isEmpty ? "none" : workspace.githubOwners.joined(separator: ", ")))
        lines.append("  Jira projects: " + (workspace.jiraProjects.isEmpty ? "none" : workspace.jiraProjects.joined(separator: ", ")))
        lines.append("  Slack: " + (workspace.slack.map { "reads \($0)" } ?? "off"))
        if !workspace.extraFiles.isEmpty { lines.append("  extra instruction files: " + workspace.extraFiles.joined(separator: ", ")) }
        lines.append("  spaces: " + (workspace.spaces.isEmpty ? "none" : workspace.spaces.map { "\($0.name) (id \($0.id), \($0.icon), \($0.color))" }.joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }

    static func markdown(_ workspaces: [Workspace], only: String? = nil) -> String {
        let shown = workspaces.filter { only == nil || $0.id.caseInsensitiveCompare(only!) == .orderedSame || $0.name.caseInsensitiveCompare(only!) == .orderedSame }
        return shown.isEmpty ? "No workspace \(only ?? "").\n" : shown.map(line).joined()
    }
}
