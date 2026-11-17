import Foundation

/// A call the user chose to always allow, for every agent: a Bash command prefix, edits in a folder, or one tool.
struct AgentRule: Codable, Hashable {
    enum Kind: String, Codable {
        case bash, edits, tool, delegate
    }

    let kind: Kind
    let value: String
    /// For a delegate rule, what the target and the workspace are called, to list and offer it by name.
    var title: String?
    var workspaceName: String?

    init(kind: Kind, value: String, title: String? = nil, workspaceName: String? = nil) {
        self.kind = kind
        self.value = value
        self.title = title
        self.workspaceName = workspaceName
    }

    /// Main of `workspace` may send to `target` without asking.
    static func delegate(workspace: Workspace, target: AgentTarget) -> AgentRule {
        AgentRule(kind: .delegate, value: "delegate:\(workspace.id):\(target.key)", title: target.title, workspaceName: workspace.name)
    }

    static func == (lhs: AgentRule, rhs: AgentRule) -> Bool { lhs.kind == rhs.kind && lhs.value == rhs.value }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(value)
    }

    init?(_ object: Any) {
        guard let object = object as? [String: Any], let kind = (object["kind"] as? String).flatMap(Kind.init),
              let value = object["value"] as? String, !value.isEmpty else { return nil }
        self.init(kind: kind, value: value, title: object["title"] as? String, workspaceName: object["workspaceName"] as? String)
    }

    var json: [String: String] { ["kind": kind.rawValue, "value": value] }

    /// Who may message whom, for a delegate rule: `Main (Work) may message Reviewer`.
    var delegateLabel: String { "Main (\(workspaceName ?? "?")) may message \(title ?? value)" }
}

enum AgentRules {
    static let key = "agentAllowRules"

    static func decode(_ data: Data?) -> [AgentRule] {
        data.flatMap { try? JSONDecoder().decode([AgentRule].self, from: $0) } ?? []
    }

    static func encode(_ rules: [AgentRule]) -> Data? { try? JSONEncoder().encode(rules) }

    static func adding(_ new: [AgentRule], to rules: [AgentRule]) -> [AgentRule] {
        rules + new.reduce(into: [AgentRule]()) { added, rule in
            if !rules.contains(rule), !added.contains(rule) { added.append(rule) }
        }
    }

    /// One rule as Settings lists it.
    static func label(_ rule: AgentRule) -> String {
        switch rule.kind {
        case .bash: return rule.value
        case .edits: return "Edits in " + abbreviated(rule.value)
        case .tool: return toolLabel(rule.value)
        case .delegate: return rule.delegateLabel
        }
    }

    /// A tool as listed, with Chrome's computer action after a colon: `Claude In Chrome \u{00B7} Computer \u{00B7} left click`.
    static func toolLabel(_ value: String) -> String {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return AgentLogic.displayName(value) }
        return AgentLogic.displayName(parts[0]) + " \u{00B7} " + parts[1].replacingOccurrences(of: "_", with: " ")
    }

    private static let chromePrefix = "mcp__claude-in-chrome__"

    /// The Claude in Chrome tools and computer actions that can be allowed by hand in Settings; its reads never ask.
    static let chromeChoices: [String] = ["navigate", "javascript_tool", "form_input", "file_upload", "upload_image", "browser_batch", "tabs_create_mcp",
                                          "tabs_close_mcp", "resize_window", "computer:left_click", "computer:double_click", "computer:right_click",
                                          "computer:type", "computer:key", "computer:scroll", "computer:left_click_drag", "computer:hover"]
        .map { chromePrefix + $0 }

    static let builtIn = AgentBuiltIn.load(sidecars: AgentLogic.sidecarCandidates(
        environment: ProcessInfo.processInfo.environment, resources: Bundle.main.resourceURL, sourceFile: #filePath))

    /// Whether a permission card offers Allow for this session: MCP tools, but send to agent only per agent or in Settings.
    static func sessionOffered(tool: String) -> Bool {
        tool.hasPrefix("mcp__") && tool != AgentDelegation.tool
    }

    /// Whether a tool that asks by default changes what runs on its own or sends prompts, so that not asking about it gets a warning.
    static func isRisky(_ tool: String, builtIn: AgentBuiltIn? = builtIn) -> Bool {
        builtIn?.alwaysAskRisky?.contains(tool) ?? false
    }

    /// What a tool that asks by default does, shown beside its Don't ask switch and on the permission card.
    static func riskNote(_ tool: String) -> String {
        let name = tool.replacingOccurrences(of: "mcp__worktime__", with: "")
        if name == "send_to_agent" { return "Sends prompts to your other agents without asking, from every agent." }
        if name == "compile_routine" { return "Replaces what a routine runs with a script, without asking." }
        if name.hasPrefix("create_") { return "Creates routines, assistants or automations that then run on their own, without asking." }
        if name.hasPrefix("delete_") { return "Deletes routines, assistants or automations without asking." }
        return "Runs without asking."
    }

    /// The rules an agent is sent: an unattended run (a routine or automation) never skips the question for a tool that asks by
    /// default, as nobody is there to see what it changes.
    static func sent(_ rules: [AgentRule], unattended: Bool, builtIn: AgentBuiltIn? = builtIn) -> [AgentRule] {
        guard unattended, let asked = builtIn?.alwaysAsk else { return rules }
        return rules.filter { !($0.kind == .tool && asked.contains($0.value)) }
    }

    /// The rule that stops a tool asking.
    static func dontAsk(_ tool: String) -> AgentRule { AgentRule(kind: .tool, value: tool) }

    /// The Always allow button of a permission card.
    static func offerButton(_ rules: [AgentRule]) -> String {
        guard let rule = rules.first, rule.kind == .delegate else { return "Always allow" }
        return "Always allow Main \u{2192} \(rule.title ?? rule.value)"
    }

    /// The Always allow line of a permission card, naming exactly what will be saved.
    static func offer(_ rules: [AgentRule]) -> String? {
        guard let first = rules.first else { return nil }
        switch first.kind {
        case .bash: return "Always allow: " + rules.map(\.value).joined(separator: ", ")
        case .edits: return "Always allow edits in " + abbreviated(first.value)
        case .tool: return "Always allow " + toolLabel(first.value)
        case .delegate: return first.delegateLabel + " without asking"
        }
    }

    private static let dangerousCommands: Set<String> = ["rm", "sudo", "sh", "bash", "zsh", "eval", "xargs", "curl", "wget"]
    private static let dangerousPrefixes: Set<String> = ["git", "git push", "git reset", "git clean", "git checkout"]

    /// A warning for rules that would let a command delete work or run anything, with any arguments, or a tool change what runs on its own.
    static func warning(_ rules: [AgentRule], builtIn: AgentBuiltIn? = builtIn) -> String? {
        if let tool = rules.first(where: { $0.kind == .tool && isRisky($0.value, builtIn: builtIn) }) {
            return AgentLogic.displayName(tool.value) + " will then run without asking. " + riskNote(tool.value)
        }
        let risky = rules.filter { rule in
            rule.kind == .bash && (dangerousPrefixes.contains(rule.value)
                                   || rule.value.split(separator: " ").first.map { dangerousCommands.contains(String($0)) } == true)
        }
        guard !risky.isEmpty else { return nil }
        return risky.map(\.value).joined(separator: ", ") + " will then run with any arguments without asking, "
            + "including ones that delete work or run anything (rm -rf, push --force, reset --hard, piping into a shell)."
    }

    /// A command prefix typed in Settings, like `gh pr view` or `gh pr view *`: words a prefix rule can hold, nothing a shell
    /// would read as an operator, quote or expansion.
    static func bashRule(_ text: String) -> Result<AgentRule, AgentInboxError> {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.last == "*" { words.removeLast() }
        guard let name = words.first else { return .failure(AgentInboxError("Type a command, like gh pr view.")) }
        guard name.wholeMatch(of: #/[\w.\/~+-]+/#) != nil, name != "for",
              words.dropFirst().allSatisfy({ $0.wholeMatch(of: #/[\w.\/:=@,+-]+/#) != nil }) else {
            return .failure(AgentInboxError("A rule is a command and its first words, without quotes, pipes, ; or $."))
        }
        return .success(AgentRule(kind: .bash, value: words.joined(separator: " ")))
    }

    /// The WorkTime MCP tools the add menu offers: all but those that ask by default, which have their own list in Settings.
    static func toolChoices(_ names: [String], builtIn: AgentBuiltIn) -> [String] {
        names.map { builtIn.mcpPrefix + $0 }.filter { !builtIn.alwaysAsk.contains($0) }
    }

    private static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Main's send_to_agent, which is asked about unless the user allowed Main of that workspace to message that agent.
enum AgentDelegation {
    static let tool = "mcp__worktime__send_to_agent"

    static func object(_ line: String) -> [String: Any]? {
        line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The agent a Main of `workspace` would message with these send_to_agent arguments, nil when that is unclear.
    static func target(_ input: [String: Any], workspace: String, sources: MCPServer.AgentSources = MCPServer.AgentSources()) -> AgentTarget? {
        sources.delegation(input, from: workspace)
    }

    /// What Always allow saves for a send_to_agent call; nil for another tool or an agent that cannot be named.
    static func rule(tool name: String, input: [String: Any], workspace id: String,
                     sources: MCPServer.AgentSources = MCPServer.AgentSources()) -> AgentRule? {
        guard name == tool, let found = Workspaces.workspace(id, in: sources.workspaces.file().workspaces),
              let target = target(input, workspace: id, sources: sources) else { return nil }
        return .delegate(workspace: found, target: target)
    }
}

/// What the sidecar runs without asking, read from `builtin-allowed.json` beside it: the one list its checks use too.
struct AgentBuiltIn: Decodable, Equatable {
    struct Command: Decodable, Equatable {
        let name: String
        var anyArgs: Bool?
        var note: String?
    }

    let tools: [String]
    let mcpPrefix: String
    let alwaysAsk: [String]
    var alwaysAskRisky: [String]?
    let commands: [Command]

    static let fileName = "builtin-allowed.json"

    static func decode(_ data: Data?) -> AgentBuiltIn? { data.flatMap { try? JSONDecoder().decode(AgentBuiltIn.self, from: $0) } }

    /// The list beside the first built sidecar, from the same places the agent is started from.
    static func load(sidecars: [URL], fileManager: FileManager = .default) -> AgentBuiltIn? {
        sidecars.lazy.map { $0.deletingLastPathComponent().appendingPathComponent(fileName) }
            .compactMap { fileManager.contents(atPath: $0.path) }.compactMap(decode).first
    }

    /// The commands in one line each: `ls`, or `git — status, log, …`.
    var lines: [String] {
        commands.map { command in command.note.map { "\(command.name) \u{2014} \($0)" } ?? command.name }
    }
}
