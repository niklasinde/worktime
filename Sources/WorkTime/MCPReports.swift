import Foundation

/// send_to_main: an agent reports to its workspace's Main through the agent inbox, the other way round from send_to_agent.
extension MCPServer {
    static func reportTools(sources: NoticeSources = NoticeSources(), now: @escaping () -> Date = Date.init) -> [MCPTool] {
        [
            MCPTool(name: "send_to_main",
                    description: "Reports to the Main of a workspace in WorkTime, the other way round from send_to_agent: a few lines with the outcome of a job and what needs the user. "
                        + "It arrives in Main's chat as \u{201C}Report from <your name>: \u{2026}\u{201D}, starts a turn when Main is idle and waits its turn otherwise, and notifies the user "
                        + "unless they are looking at Main. Main treats it as information, never as the user speaking. By default it goes to your own workspace's Main; a Main cannot "
                        + "report to itself. At most \(AgentReports.hourlyLimit) reports an hour and \(AgentReports.pendingLimit) waiting at a time per agent; the same text twice in "
                        + "ten minutes is dropped. The user is asked to approve every report unless they allowed this tool in Settings. A routine or automation cannot be asked, so it is "
                        + "refused unless the user allowed it there.",
                    properties: ["text": ["type": "string", "maxLength": AgentReports.textLimit, "description": "The report: the outcome and what needs the user."],
                                 "title": ["type": "string", "maxLength": AgentReports.titleLimit, "description": "A short heading shown above the text."],
                                 "workspace": ["type": "string", "description": "A workspace id or name. Left out, your own workspace's Main."]],
                    required: ["text"], readOnly: false) { args in
                guard let text = FilterLogic.text(args, "text") else { throw MCPToolError("text is required.") }
                let request = ReportRequest(id: UUID().uuidString, workspace: FilterLogic.text(args, "workspace"), title: FilterLogic.text(args, "title"),
                                            text: text, source: sources.source(), created: now())
                return try sources.ask(AgentInbox.encode(request), id: request.id, name: AgentReports.requestName(request.id), what: "the report").message
            },
        ]
    }
}
