import Foundation

/// Runs a routine's script in the app with the read-only tools the MCP server offers, and tells the analysis what they are.
enum RoutineScriptRunner {
    /// The server's tools a script may call, by name: allowed by name and read-only by the server's own flag.
    static func tools() -> [String: MCPTool] {
        let store = Result { try MeetingStore.openReadOnly() }
        let github = MCPServer.githubTools(store)
        let all = MCPServer.meetingTools(store) + github + MCPServer.agentTools(store, github: github) + MCPServer.topicTools() + MCPServer.resumeTools(store)
        return Dictionary(all.filter { $0.readOnly && RoutineScripts.allowedTools.contains($0.name) }.map { ($0.name, $0) }) { first, _ in first }
    }

    static func infos(_ tools: [String: MCPTool]) -> [ScriptToolInfo] {
        tools.values.sorted { $0.name < $1.name }.map { tool in
            let first = tool.description.components(separatedBy: ". ").first ?? tool.description
            return ScriptToolInfo(name: tool.name, summary: first.hasSuffix(".") ? String(first.dropLast()) : first, arguments: tool.properties.keys.sorted())
        }
    }

    static func run(_ script: RoutineScript, context: [String: String]) async -> ScriptResult {
        await Task.detached(priority: .utility) {
            let available = tools()
            return RoutineScripts.run(script, context: context.merging(RoutineScripts.builtinValues(now: Date())) { given, _ in given }) { name, args in
                guard let tool = available[name] else { throw MCPToolError("\(name) is not available to a script.") }
                return try tool.run(args)
            }
        }.value
    }
}
