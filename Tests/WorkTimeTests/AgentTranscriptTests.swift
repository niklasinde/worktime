import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func call(_ id: String, command: String = "git push", result: String? = nil, isError: Bool = false) -> AgentItem {
    AgentItem(id: "tool-\(id)", kind: .tool(name: "Bash", summary: command, detail: command, result: result, isError: isError, auto: false), call: id)
}

private func prompt(_ call: String, allowed: Bool?, command: String = "git push") -> AgentItem {
    AgentItem(id: "permission-\(call)-1", kind: .permission(tool: "Bash", summary: command, detail: command, allowed: allowed), call: call)
}

private func ids(_ blocks: [AgentToolGroups.Block]) -> [String] { blocks.map(\.id) }

let agentTranscriptTests: [(name: String, run: () throws -> Void)] = [
    ("transcript: an answered prompt shows as its tool row with the decision, never as a card besides it", {
        let items = [call("a", result: "refused", isError: true), prompt("a", allowed: false)]
        let merged = AgentToolGroups.merged(items)
        check(merged.map(\.id) == ["tool-a"], "one row: \(merged.map(\.id))")
        check(merged[0].decision == false, "denied")
        let allowed = AgentToolGroups.merged([call("b"), prompt("b", allowed: true)])
        check(allowed.count == 1 && allowed[0].decision == true, "allowed while it runs")
    }),
    ("transcript: a prompt still waiting is the card alone, and the row behind it stays out of sight", {
        let merged = AgentToolGroups.merged([call("a"), prompt("a", allowed: nil)])
        check(merged.map(\.id) == ["permission-a-1"], "\(merged.map(\.id))")
    }),
    ("transcript: items without a call id, or a prompt without its row, are left alone", {
        let old = AgentItem(id: "permission-1-1", kind: .permission(tool: "Bash", summary: "ls", detail: "ls", allowed: false))
        check(AgentToolGroups.merged([old]).count == 1, "an old prompt stays")
        check(AgentToolGroups.merged([prompt("x", allowed: true)]).count == 1, "no row to merge into")
    }),
    ("transcript: the same refused call again folds into one row with a count", {
        let items = [call("a", isError: true), prompt("a", allowed: false), call("b", isError: true), prompt("b", allowed: false),
                     call("c", command: "rm -rf x", isError: true), prompt("c", allowed: false, command: "rm -rf x")]
        let blocks = AgentToolGroups.blocks(items)
        check(ids(blocks) == ["tool-a", "tool-c"], "\(ids(blocks))")
        guard case .item(let first) = blocks[0] else { return check(false, "item") }
        check(first.repeats == 2, "counted: \(first.repeats)")
        let apart = AgentToolGroups.collapsed([call("a", isError: true), AgentItem(id: "t", kind: .text("hi")), call("b", isError: true)].map { var item = $0; if item.call != nil { item.decision = false }; return item })
        check(apart.count == 3, "a message between keeps them apart")
    }),
    ("transcript: an unattended run gathers what was refused into one row at the end", {
        let items = [call("a", isError: true), prompt("a", allowed: false), call("b", result: "ok"), call("c", result: "ok"),
                     call("d", command: "gh pr review", isError: true), prompt("d", allowed: false, command: "gh pr review"),
                     AgentItem(id: "text-1", kind: .text("done"))]
        let blocks = AgentToolGroups.blocks(items, unattended: true)
        guard case .refused(_, let refused, let label) = blocks.last else { return check(false, "refused last: \(ids(blocks))") }
        check(refused.count == 2 && label == "2 calls were refused: nobody was there to approve", "\(label)")
        check(blocks.count == 3, "a group, the text, the refusals: \(ids(blocks))")
        let attended = AgentToolGroups.blocks(items)
        check(!attended.contains { if case .refused = $0 { true } else { false } }, "an attended chat keeps them in place")
        check(AgentToolGroups.refusedLabel(1) == "1 call was refused: nobody was there to approve", "singular")
    }),
    ("transcript: the sidecar's tool call id links a prompt to its row", {
        let line = #"{"type":"permission_request","id":"3","toolUseId":"toolu_9","tool":"Bash","input":{"command":"ls"},"offer":[]}"#
        guard case .permissionRequest(_, _, _, _, _, let toolUse)? = AgentEvent.decode(line, cwd: "/w") else { return check(false, "decoded") }
        check(toolUse == "toolu_9", "\(String(describing: toolUse))")
        var items: [AgentItem] = []
        AgentLogic.apply(.toolUse(id: "toolu_9", tool: "Bash", summary: "ls", detail: "ls"), to: &items)
        AgentLogic.apply(.permissionRequest(id: "3", tool: "Bash", summary: "ls", detail: "ls", toolUse: "toolu_9"), to: &items)
        check(items.map(\.call) == ["toolu_9", "toolu_9"], "both carry it")
    }),
    ("commands: a heredoc reads as the file it writes", {
        check(AgentCommands.summary("cat > api_review.md <<'EOF'\n[AI]\nbody\nEOF") == "write api_review.md (heredoc)", "cat")
        let long = "mkdir -p /tmp/x && cd /tmp/x && cat >> notes/log.txt << EOF\nline\nEOF"
        check(AgentCommands.summary(long) == "append to log.txt (heredoc)", AgentCommands.summary(long))
        check(AgentCommands.summary("tee -a out.md <<'END'\nx\nEND") == "append to out.md (heredoc)", "tee")
        check(AgentCommands.summary("cat file.txt") == "cat file.txt", "a plain cat")
        check(AgentCommands.heredoc("echo hi > file") == nil, "no heredoc")
    }),
    ("commands: the scratchpad and the home folder are shortened in a summary", {
        let path = "/private/tmp/claude-501/-Users-me-git-orbit/089fe12b-950d-436a-ab3b-2b735a4fb1f1/scratchpad"
        check(AgentCommands.summary("mkdir -p \(path)/out && ls") == "mkdir -p scratchpad/out && ls", AgentCommands.summary("mkdir -p \(path)/out && ls"))
        check(AgentCommands.shortened("ls /Users/me/git/orbit", home: "/Users/me") == "ls ~/git/orbit", "home")
        check(AgentCommands.shortened("ls /Users/mer/x", home: "/Users/me") == "ls /Users/mer/x", "only a whole folder")
        check(AgentCommands.shortened("ls /x", home: "/") == "ls /x", "a root home is left alone")
        check(AgentLogic.summary(tool: "Bash", input: ["command": "cat > a.md <<'EOF'\nx\nEOF"], cwd: "/w") == "write a.md (heredoc)", "used by the tool row")
    }),
]
