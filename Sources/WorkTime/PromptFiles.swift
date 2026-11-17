import Foundation

/// Where a prompt template is kept: for every workspace, or for one.
enum PromptScope: Hashable, Sendable {
    case shared
    case workspace(String)
}

/// The template files on disk, read each time a prompt is made so an edit applies at once. A workspace's own file wins, then the shared
/// one, then the built-in text; an empty file counts as none.
struct PromptFiles: Sendable {
    static let sharedFolder = "_shared"
    static let folderName = "Prompts"

    /// The files the app uses. Tests point it at a folder of their own.
    nonisolated(unsafe) static var current = PromptFiles()

    var folder: URL = AppPaths.workspaceFolders

    func directory(_ scope: PromptScope) -> URL {
        let name: String
        switch scope {
        case .shared: name = Self.sharedFolder
        case .workspace(let id): name = id
        }
        return folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(Self.folderName, isDirectory: true)
    }

    func url(_ template: PromptTemplate, scope: PromptScope) -> URL {
        directory(scope).appendingPathComponent(template.fileName)
    }

    /// What the file holds apart from its front matter, nil when there is no file or nothing in it.
    func stored(_ template: PromptTemplate, scope: PromptScope) -> (body: String, version: Int?)? {
        guard let text = try? String(contentsOf: url(template, scope: scope), encoding: .utf8) else { return nil }
        let parsed = PromptTemplates.parse(text)
        return parsed.body.isEmpty ? nil : parsed
    }

    enum Source: Equatable, Sendable {
        case workspace, shared, builtIn
    }

    func resolve(_ template: PromptTemplate, workspace: String? = nil) -> (text: String, source: Source) {
        if let workspace, let own = stored(template, scope: .workspace(workspace)) { return (own.body, .workspace) }
        if let shared = stored(template, scope: .shared) { return (shared.body, .shared) }
        return (template.builtIn.trimmingCharacters(in: .whitespacesAndNewlines), .builtIn)
    }

    /// Writes the shared file of every template that has none, so the text can be found and edited. A file that exists is never touched.
    func seed() {
        for template in PromptTemplate.allCases where !FileManager.default.fileExists(atPath: url(template, scope: .shared).path) {
            write(template.builtIn, template, scope: .shared)
        }
    }

    func write(_ body: String, _ template: PromptTemplate, scope: PromptScope) {
        let url = url(template, scope: scope)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(PromptTemplates.file(template, body: body).utf8).write(to: url, options: .atomic)
    }

    /// The shared file goes back to the built-in text; a workspace's own file is removed, so the shared one applies again.
    func reset(_ template: PromptTemplate, scope: PromptScope) {
        switch scope {
        case .shared: write(template.builtIn, template, scope: .shared)
        case .workspace: try? FileManager.default.removeItem(at: url(template, scope: scope))
        }
    }

    /// Whether the file at `scope` differs from what a reset would leave: for a workspace, whether it has a file of its own.
    func isChanged(_ template: PromptTemplate, scope: PromptScope) -> Bool {
        guard let own = stored(template, scope: scope) else { return false }
        switch scope {
        case .shared: return own.body != template.builtIn.trimmingCharacters(in: .whitespacesAndNewlines)
        case .workspace: return true
        }
    }

    /// Whether the built-in text has moved on since the file was written.
    func isOutdated(_ template: PromptTemplate, scope: PromptScope) -> Bool {
        guard let own = stored(template, scope: scope) else { return false }
        return (own.version ?? 0) < template.version
    }
}

extension PromptTemplates {
    /// A template's text for a workspace, with its placeholders still in it.
    static func body(_ template: PromptTemplate, workspace: String? = nil, files: PromptFiles = .current) -> String {
        files.resolve(template, workspace: workspace).text
    }

    /// A template's text with `values` in the place of its placeholders. `{draft_format}` is always filled in from its own template unless
    /// `values` holds it, so a prompt carries the format as the workspace has it.
    static func render(_ template: PromptTemplate, _ values: [String: String] = [:], workspace: String? = nil, files: PromptFiles = .current) -> String {
        var values = values
        if values["draft_format"] == nil, template != .reviewDraftFormat {
            values["draft_format"] = body(.reviewDraftFormat, workspace: workspace, files: files)
        }
        return render(body(template, workspace: workspace, files: files), values)
    }

    /// The texts the sidecar adds to every agent's system prompt, by the names it reads them under: the three templates and, with the
    /// agent's `locations`, where its files live.
    static func agentInstructions(workspace: String? = nil, locations: AgentWhere? = nil, files: PromptFiles = .current) -> [String: String] {
        var texts = ["actions": body(.agentActions, workspace: workspace, files: files), "review": body(.agentReview, workspace: workspace, files: files),
                     "report": body(.agentReport, workspace: workspace, files: files)]
        if let locations { texts["where"] = render(body(.agentWhere, workspace: workspace, files: files), locations.values) }
        return texts
    }
}
