import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let builtIn = AgentBuiltIn.decode(Data("""
{"tools": ["Read"], "mcpPrefix": "mcp__worktime__",
 "alwaysAsk": ["mcp__worktime__update_routine", "mcp__worktime__create_routine"],
 "alwaysAskRisky": ["mcp__worktime__create_routine"], "commands": []}
""".utf8))

private func role(_ tools: String?, extra: String = "") -> String {
    var lines = ["---", "name: Checker", "icon: eye", "description: Checks things.", "model: sonnet", "permissionMode: ask"]
    if let tools { lines.append(contentsOf: tools.components(separatedBy: "\n")) }
    lines.append(extra.isEmpty ? "---" : extra + "\n---")
    return lines.joined(separator: "\n") + "\n\n# Checker\n\nLook closely.\n"
}

private func tools(_ text: String) -> [String] { Assistants.parse(slug: "x", text: text).tools }

private func item(_ id: String, _ kind: AgentItem.Kind) -> AgentItem { AgentItem(id: id, kind: kind) }

let roleToolTests: [(name: String, run: () throws -> Void)] = [
    ("role tools: adding to an empty inline list, an inline list and a plain list", {
        let empty = RoleTools.adding("mcp__worktime__jira_issue", to: role("tools: []"))
        check(empty.map(tools) == ["jira_issue"], "empty: \(String(describing: empty))")
        let inline = RoleTools.adding("mcp__worktime__jira_search", to: role("tools: [github_pr, jira_issue]"))
        check(inline.map(tools) == ["github_pr", "jira_issue", "jira_search"], "inline")
        check(inline?.contains("tools: [github_pr, jira_issue, jira_search]") == true, "written as an inline list again")
        let plain = RoleTools.adding("jira_search", to: role("tools: github_pr, jira_issue"))
        check(plain.map(tools) == ["github_pr", "jira_issue", "jira_search"], "plain list")
    }),
    ("role tools: adding to a block list keeps its indentation, and a file without the key gets one", {
        let block = RoleTools.adding("mcp__worktime__slack_search", to: role("tools:\n    - github_pr\n    - jira_issue"))
        check(block.map(tools) == ["github_pr", "jira_issue", "slack_search"], "block: \(String(describing: block))")
        check(block?.contains("    - slack_search\n") == true, "same indentation")
        let missing = RoleTools.adding("mcp__worktime__slack_search", to: role(nil))
        check(missing.map(tools) == ["slack_search"], "a new line")
        check(missing?.contains("tools: [slack_search]\n---") == true, "put before the closing line")
    }),
    ("role tools: quoted names stay, the rest of the file is untouched, and a tool already there is left alone", {
        let original = role("tools: [\"github_pr\", 'jira_issue']")
        let updated = RoleTools.adding("mcp__worktime__time_report", to: original)
        check(updated.map(tools) == ["github_pr", "jira_issue", "time_report"], "quoted names")
        check(updated?.contains("[\"github_pr\", 'jira_issue', time_report]") == true, "quotes kept")
        let a = original.components(separatedBy: "\n"), b = (updated ?? "").components(separatedBy: "\n")
        check(a.filter { !$0.hasPrefix("tools:") } == b.filter { !$0.hasPrefix("tools:") }, "every other line is the same")
        check(RoleTools.adding("jira_issue", to: original) == original, "short name already there")
        check(RoleTools.adding("mcp__worktime__github_pr", to: original) == original, "full name already there")
        check(RoleTools.adding("jira_issue", to: "no front matter") == nil, "nothing to edit")
    }),
    ("role tools: a file with Windows line endings stays that way", {
        let crlf = role("tools: [github_pr]").replacingOccurrences(of: "\n", with: "\r\n")
        let updated = RoleTools.adding("jira_issue", to: crlf)
        check(updated.map(tools) == ["github_pr", "jira_issue"], "read back")
        check(updated?.contains("tools: [github_pr, jira_issue]\r\n") == true, "line ending kept")
        check(updated?.replacingOccurrences(of: "\r\n", with: "").contains("\n") == false, "no bare newline added")
    }),
    ("role tools: a tool is read, asks or is risky, as the built-in list says", {
        check(RoleTools.tier(of: "mcp__worktime__jira_issue", builtIn: builtIn) == .read, "read")
        check(RoleTools.tier(of: "update_routine", builtIn: builtIn) == .ask, "asks")
        check(RoleTools.tier(of: "mcp__worktime__create_routine", builtIn: builtIn) == .risky, "risky")
        check(RoleTools.note(tool: "x", tier: .read) == nil, "no note for a read tool")
        check(RoleTools.note(tool: "mcp__worktime__update_routine", tier: .ask)?.contains("asks about every call") == true, "asks note")
        check(RoleTools.note(tool: "mcp__worktime__create_routine", tier: .risky)?.contains("Creates routines") == true, "the risky tier's warning")
        let rule = RoleTools.offer(tool: "mcp__worktime__create_routine", tier: .risky, assistant: "Checker")
        check(rule.kind == .role && RoleTools.tier(of: rule) == .risky && rule.workspaceName == "Checker", "the offer carries tier and assistant")
        let jira = AgentLogic.displayName("mcp__worktime__jira_issue")
        check(RoleTools.title(tool: "mcp__worktime__jira_issue", assistant: "Checker") == "Checker wants to use \(jira), which is not in its tools", "card title")
    }),
    ("role tools: what the agent reads after a refusal says who was asked", {
        check(RoleTools.refusal(tool: "t", waited: false, unattended: false) == "The user denied this tool call.", "denied")
        check(RoleTools.refusal(tool: "t", waited: false, unattended: true).contains("will be asked after this run"), "unattended")
        check(RoleTools.refusal(tool: "t", waited: true, unattended: true).contains("nobody answered"), "timeout")
        check(RoleToolWait.rowText(tool: "mcp__worktime__jira_issue") == "waiting for you: \(AgentLogic.displayName("mcp__worktime__jira_issue"))", "routine row")
        let defaults = UserDefaults(suiteName: "role-\(UUID().uuidString)")!
        check(RoleTools.waitSeconds(defaults: defaults) == 30 * 60, "30 minutes by default")
        defaults.set(5, forKey: RoleTools.waitKey)
        check(RoleTools.waitSeconds(defaults: defaults) == 300, "from the setting")
        defaults.set(0, forKey: RoleTools.waitKey)
        check(RoleTools.waitSeconds(defaults: defaults) == 60, "never less than a minute")
    }),
    ("role tools: an unattended run's suggestion is kept once for each assistant and tool, and a dismissed one is not asked again", {
        let first = RoleToolSuggestion(assistant: "assistant:work:checker", assistantName: "Checker", tool: "mcp__worktime__jira_issue", routine: "Morning", created: Date(timeIntervalSince1970: 1))
        let again = RoleToolSuggestion(assistant: "assistant:work:checker", assistantName: "Checker", tool: "jira_issue", routine: "Evening", created: Date(timeIntervalSince1970: 2))
        let other = RoleToolSuggestion(assistant: "assistant:work:checker", assistantName: "Checker", tool: "jira_search", routine: "Morning", created: Date(timeIntervalSince1970: 3))
        var list = RoleToolSuggestions.adding(first, to: [])
        list = RoleToolSuggestions.adding(again, to: list)
        check(list.count == 1 && list[0].routine == "Morning", "the same tool by either name is one suggestion")
        list = RoleToolSuggestions.adding(other, to: list)
        check(list.count == 2, "another tool is another suggestion")
        check(!RoleToolSuggestions.shouldAsk(again, pending: list, dismissed: []), "already pending")
        check(!RoleToolSuggestions.shouldAsk(other, pending: [], dismissed: [other.id]), "dismissed")
        check(RoleToolSuggestions.shouldAsk(other, pending: [], dismissed: []), "new")
        check(RoleToolSuggestions.removing(first.id, from: list) == [other], "removed")
        let words = RoleToolSuggestions.text(first)
        check(words.title == "Morning needed \(AgentLogic.displayName("mcp__worktime__jira_issue"))" && words.body == "Add it to Checker\u{2019}s tools?", "words: \(words)")
        let many = (0..<60).map { RoleToolSuggestion(assistant: "a", assistantName: "A", tool: "t\($0)", routine: "r", created: Date()) }
        check(many.reduce([]) { RoleToolSuggestions.adding($1, to: $0) }.count == RoleToolSuggestions.limit, "capped")
        let data = RoleToolSuggestions.encode(list)
        check(RoleToolSuggestions.decode(data) == list, "saved and read back")
    }),
    ("role tools: the sidecar's question and answers read and write as the app and the sidecar expect", {
        let line = #"{"type":"permission_request","id":"4","toolUseId":"t1","tool":"mcp__worktime__jira_issue","input":{"key":"ABC-1"},"roleTool":true,"tier":"ask","offer":[]}"#
        guard case .permissionRequest(let id, let tool, _, _, let offer, let toolUse)? = AgentEvent.decode(line, cwd: "/tmp") else { return check(false, "decoded") }
        check(id == "4" && tool == "mcp__worktime__jira_issue" && toolUse == "t1", "ids")
        check(offer.count == 1 && offer[0].kind == .role && RoleTools.tier(of: offer[0]) == .ask, "the offer is the role rule with its tier")
        check(AgentEvent.decode(#"{"type":"role_timeout","id":"4"}"#, cwd: "/tmp") == .roleTimeout(id: "4"), "timeout")
        let add = AgentRequest.permission(id: "4", allow: true, session: false, add: true).line
        check(add.contains("\"add\":true") && !add.contains("\"session\""), "add: \(add)")
        let denied = AgentRequest.permission(id: "4", allow: false, message: "Nobody answered.").line
        check(denied.contains("\"message\":\"Nobody answered.\"") && denied.contains("\"allow\":false"), "message: \(denied)")
        check(AgentRequest.allowSession(key: "mcp__worktime__jira_issue").line.contains("\"type\":\"allow_session\""), "allow_session")
        let prompt = AgentRequest.prompt(text: "go", cwd: "/tmp", sessionID: nil, roleWaitSeconds: 1800).line
        check(prompt.contains("\"roleWaitSeconds\":1800"), "the wait limit goes with the prompt")
        check(!AgentRequest.prompt(text: "go", cwd: "/tmp", sessionID: nil).line.contains("roleWaitSeconds"), "none for an attended run")
    }),
    ("attention: the tool question has its own buttons and answers, also for a routine", {
        check(AgentAttention.approvalCategory(sessionOffered: true, roleTool: true) == AgentAttention.roleToolCategory, "category")
        check(AgentAttention.approvalCategory(sessionOffered: true) == AgentAttention.sessionApprovalCategory, "unchanged")
        check(AgentAttention.response(action: AgentAttention.addToolAction, text: nil) == .addTool, "add")
        check(AgentAttention.response(action: AgentAttention.fixAction, text: nil) == .fixAndContinue, "fix and continue")
        check(AgentAttention.response(action: AgentAttention.dismissAction, text: nil) == .dismiss, "dismiss")
        check(AgentAttention.shouldNotifyRoleTool(enabled: true, isShown: false), "a routine waiting for the answer notifies")
        check(!AgentAttention.shouldNotifyRoleTool(enabled: true, isShown: true), "not while the agent is in front")
        check(!AgentAttention.shouldNotifyRoleTool(enabled: false, isShown: false), "setting off")
        let text = RoleTools.approval(agent: "Checker", tool: "mcp__worktime__create_routine", tier: .risky)
        check(text.title == "Checker needs a tool" && text.body.contains("not in its tools") && text.body.contains("Creates routines"), "words: \(text)")
    }),
    ("blocked: the refused calls of the last turn, once each, with their fixes", {
        let denied = AgentItem.Kind.permission(tool: "mcp__worktime__jira_issue", summary: "ABC-1", detail: "", offer: [RoleTools.offer(tool: "mcp__worktime__jira_issue", tier: .read)], allowed: false)
        let items = [
            item("user-0", .user("old turn")),
            item("permission-1-1", .permission(tool: "mcp__worktime__old", summary: "", detail: "", offer: [], allowed: false)),
            item("user-2", .user("go")),
            item("permission-2-3", denied),
            item("tool-a", .tool(name: "mcp__worktime__jira_issue", summary: "ABC-1", detail: "", result: "mcp__worktime__jira_issue is not one of this assistant's tools.", isError: true, auto: false)),
            item("tool-b", .tool(name: "mcp__worktime__slack_search", summary: "deploy", detail: "", result: "mcp__worktime__slack_search is not one of this assistant's tools.", isError: true, auto: false)),
            item("tool-c", .tool(name: "mcp__claude-in-chrome__navigate", summary: "https://example.com", detail: "", result: "No such tool", isError: true, auto: false)),
            item("tool-d", .tool(name: "mcp__worktime__update_routine", summary: "x", detail: "", result: "The user denied this tool call.", isError: true, auto: false)),
            item("tool-e", .tool(name: "Read", summary: "a", detail: "", result: "fine", isError: false, auto: true)),
        ]
        let calls = Blocked.calls(in: items, chromeOn: false, assistant: "Checker")
        check(calls.map(\.tool) == ["mcp__worktime__jira_issue", "mcp__worktime__slack_search", "mcp__claude-in-chrome__navigate", "mcp__worktime__update_routine"], "tools: \(calls.map(\.tool))")
        check(calls[0].fixes == [.addTool("mcp__worktime__jira_issue")] && calls[0].reason == "Not in Checker\u{2019}s tools", "the question denied, once")
        check(calls[1].fixes == [.addTool("mcp__worktime__slack_search")], "an older refusal result")
        check(calls[2].fixes == [.chromeOn], "chrome off")
        check(calls[3].fixes == [.allowSession("mcp__worktime__update_routine")], "a denied call that can be allowed for the session")
        check(Blocked.calls(in: items, chromeOn: true, assistant: "Checker").count == 3, "chrome on: that call is no longer blocked")
        check(Blocked.calls(in: [item("user-0", .user("hi"))], chromeOn: true, assistant: nil).isEmpty, "nothing refused")
    }),
    ("blocked: Fix and continue applies the fixes that save no rule, once each, and says what is available", {
        let bash = AgentRule(kind: .bash, value: "gh pr")
        let items = [
            item("user-0", .user("go")),
            item("permission-1-1", .permission(tool: "Bash", summary: "gh pr view 1", detail: "gh pr view 1", offer: [bash], allowed: false)),
            item("permission-2-2", .permission(tool: "mcp__worktime__jira_issue", summary: "a", detail: "", offer: [RoleTools.offer(tool: "mcp__worktime__jira_issue", tier: .read)], allowed: false)),
            item("permission-3-3", .permission(tool: "mcp__worktime__jira_issue", summary: "b", detail: "", offer: [RoleTools.offer(tool: "mcp__worktime__jira_issue", tier: .read)], allowed: false)),
        ]
        let calls = Blocked.calls(in: items, chromeOn: true, assistant: nil)
        check(calls.count == 3 && calls[0].fixes == [.alwaysAllow([bash])], "a Bash command offers a saved rule only")
        check(Blocked.defaultFixes(calls) == [.addTool("mcp__worktime__jira_issue")], "the saved rule is not applied by itself, the tool once")
        let text = Blocked.continueText(calls)
        check(text.hasPrefix("Continue: the blocked tools are now available") && text.contains(AgentLogic.displayName("mcp__worktime__jira_issue")) && !text.contains("Bash"), "text: \(text)")
        check(Blocked.continueText([]) == "Continue: the blocked tools are now available.", "no tools to name")
        let notice = Blocked.notice(agent: "Checker", calls: calls)
        check(notice.title == "Checker was blocked" && notice.body.hasPrefix("3 calls could not run"), "notice: \(notice)")
        check(BlockedCall.Fix.chromeOn.label == "Turn Chrome on for this session" && BlockedCall.Fix.addTool("t").label == "Add to its tools", "labels")
    }),
]
