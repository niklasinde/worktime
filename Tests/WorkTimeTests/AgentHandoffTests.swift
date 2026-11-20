import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func item(_ id: String, _ kind: AgentItem.Kind, at seconds: TimeInterval) -> AgentItem {
    var item = AgentItem(id: id, kind: kind)
    item.date = Date(timeIntervalSince1970: seconds)
    return item
}

let agentHandoffTests: [(name: String, run: () throws -> Void)] = [
    ("handoff: digest keeps prompts and replies, tool calls as one line, and skips the rest", {
        let items = [
            item("u", .user("Fix the export"), at: 10),
            item("b", .tool(name: "Bash", summary: "swift test", detail: "long output", result: "ok", isError: false, auto: true), at: 11),
            item("e", .tool(name: "Edit", summary: "Sources/Export.swift", detail: "", result: nil, isError: true, auto: false), at: 12),
            item("s", .status("Thinking"), at: 13),
            item("p", .permission(tool: "Bash", summary: "git push", detail: "", allowed: true), at: 14),
            item("t", .text("Fixed and tested."), at: 15),
        ]
        let digest = AgentHandoff.digest(items: items, since: .distantPast, from: .codex)
        check(digest == "User: Fix the export\n\n[Bash swift test]\n\n[Edit Sources/Export.swift, failed]\n\nCodex: Fixed and tested.", "digest \(digest)")
        check(!digest.contains("long output") && !digest.contains("Thinking"), "no tool detail or status")
    }),
    ("handoff: an over-long digest keeps the newest turns and says it trimmed", {
        let items = (0..<20).map { item("t\($0)", .text("turn \($0) " + String(repeating: "x", count: 90)), at: Double($0)) }
        let digest = AgentHandoff.digest(items: items, since: .distantPast, from: .claude, limit: 500)
        check(digest.count <= 500, "within limit \(digest.count)")
        check(digest.hasPrefix(AgentHandoff.trimmedNote), "trim note first")
        check(digest.contains("turn 19") && !digest.contains("turn 0 "), "newest kept")
        let huge = AgentHandoff.digest(items: [item("h", .text(String(repeating: "y", count: 2000)), at: 1)], since: .distantPast, from: .claude, limit: 300)
        check(huge.count <= 300 && huge.hasPrefix(AgentHandoff.trimmedNote), "one long turn is cut \(huge.count)")
    }),
    ("handoff: an empty digest leaves the prompt alone, a full one frames it once and strips back to the user's text", {
        check(AgentHandoff.prompt("Go on", digest: nil, from: .codex) == "Go on", "nil")
        check(AgentHandoff.prompt("Go on", digest: "", from: .codex) == "Go on", "empty")
        check(AgentHandoff.digest(items: [item("s", .status("x"), at: 1)], since: .distantPast, from: .codex).isEmpty, "nothing to pass")
        let framed = AgentHandoff.prompt("Go on", digest: "User: Fix it", from: .codex)
        check(framed.hasPrefix("You are taking over from Codex.") && framed.contains("User: Fix it") && framed.hasSuffix("Go on"), "framed \(framed)")
        check(AgentHandoff.strip(framed) == "Go on", "strip")
        check(AgentHandoff.strip("Plain text") == "Plain text", "plain untouched")
    }),
    ("handoff: Claude to Codex to Claude passes Claude only what Codex did since it took over", {
        let claude = [item("c1", .user("Start"), at: 10), item("c2", .text("Started."), at: 11)]
        let toCodex = AgentHandoff.digest(items: claude, since: .distantPast, from: .claude)
        check(toCodex.contains("Started."), "Codex gets Claude's turns")
        let framed = AgentHandoff.prompt("Carry on", digest: toCodex, from: .claude)
        let codex = [item("x1", .user(AgentHandoff.strip(framed)), at: 20), item("x2", .text("Carried on."), at: 21)]
        let back = AgentHandoff.digest(items: claude + codex, since: Date(timeIntervalSince1970: 20), from: .codex)
        check(back == "User: Carry on\n\nCodex: Carried on.", "only Codex's turns \(back)")
        check(!back.contains("Started.") && !back.contains("taking over"), "nothing Claude already has")
    }),
    ("handoff: a digest queued twice before a prompt merges in order with at most one trim note, first", {
        check(AgentHandoff.merge(nil, "User: b") == "User: b", "nothing pending")
        check(AgentHandoff.merge("User: a", "") == "User: a", "nothing new")
        check(AgentHandoff.merge("User: a", "User: b") == "User: a\n\nUser: b", "in order")
        let merged = AgentHandoff.merge(AgentHandoff.trimmedNote + "\n\nUser: a", "User: b", limit: 1000)
        check(merged == AgentHandoff.trimmedNote + "\n\nUser: a\n\nUser: b", "one note, first \(merged)")
    }),
]
