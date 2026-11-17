import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func step(_ id: String, _ tool: String, _ args: [String: ScriptArg] = [:], keep: String? = nil, drop: String? = nil, limit: Int? = nil,
                  expect: String? = nil, optional: Bool? = nil) -> RoutineScript.Step {
    RoutineScript.Step(id: id, tool: tool, args: args, keep: keep, drop: drop, limit: limit, expect: expect, optional: optional)
}

private func script(_ steps: [RoutineScript.Step], output: String = "{tickets}", nonEmpty: Bool? = nil) -> RoutineScript {
    RoutineScript(steps: steps, output: output, nonEmpty: nonEmpty)
}

private func item(_ kind: AgentItem.Kind) -> AgentItem { AgentItem(id: UUID().uuidString, kind: kind) }

private func routine(prompt: String = "Brief me on my tickets", determinism: DeterministicPlan? = nil, trigger: AutomationTrigger? = nil) -> Routine {
    Routine(id: "r1", name: "Brief", prompt: prompt, workspace: "work", schedule: RoutineSchedule(kind: .weekdays), created: Date(timeIntervalSince1970: 0),
            trigger: trigger, determinism: determinism)
}

private let plan = DeterministicPlan(mode: .hybrid, version: 2, prompt: "Summarise:\n{data}", savedTokens: 900)

let determinismTests: [(name: String, run: () throws -> Void)] = [
    ("script: it survives encoding, and numbers, booleans and text keep their types", {
        let original = script([step("tickets", "jira_search", ["jql": .text("assignee = currentUser()"), "limit": .number(5), "open": .flag(true)], limit: 5)])
        guard case .success(let decoded) = RoutineScripts.decode(RoutineScripts.encode(original)) else { return check(false, "decodes") }
        check(decoded == original, "same script")
        check(decoded.steps[0].args["limit"] == .number(5) && decoded.steps[0].args["open"] == .flag(true), "types")
        guard case .failure = RoutineScripts.decode("{\"steps\": 3}") else { return check(false, "garbage fails") }
    }),

    ("script: placeholders are filled from the values, and an unknown one is left empty", {
        check(RoutineScripts.placeholders(in: "{date} {pr_url} {not a name} {x1}") == ["date", "pr_url", "x1"], "found")
        check(RoutineScripts.fill("On {date}: {a} and {missing}.", values: ["date": "2026-11-16", "a": "x"]) == "On 2026-11-16: x and .", "filled")
    }),

    ("script: only read-only tools, known placeholders, valid patterns and unique ids pass", {
        check(RoutineScripts.problem(script([step("tickets", "jira_search")])) == nil, "valid")
        for writing in ["create_routine", "send_to_agent", "notify", "add_reminder", "complete_reminder", "compile_routine", "Bash"] {
            check(RoutineScripts.problem(script([step("one", writing)]))?.contains("not allowed") == true, writing)
        }
        check(RoutineScripts.problem(script([]))?.contains("at least one") == true, "no steps")
        check(RoutineScripts.problem(script([step("a", "jira_search"), step("a", "jira_search")]))?.contains("twice") == true, "duplicate id")
        check(RoutineScripts.problem(script([step("Bad Id", "jira_search")]))?.contains("lower case") == true, "bad id")
        check(RoutineScripts.problem(script([step("a", "jira_search", keep: "(")]))?.contains("regular expression") == true, "bad pattern")
        check(RoutineScripts.problem(script([step("a", "jira_search", limit: 0)]))?.contains("limit") == true, "limit")
        check(RoutineScripts.problem(script([step("a", "jira_search", ["jql": .text("{later}")]), step("later", "jira_issue")]))?.contains("{later}") == true, "uses a later step")
        check(RoutineScripts.problem(script([step("a", "jira_search")], output: "{nothing}"))?.contains("{nothing}") == true, "unknown output placeholder")
        check(RoutineScripts.problem(script([step("a", "jira_search")], output: "  "))?.contains("output") == true, "empty output")
        check(RoutineScripts.problem(script([step("a", "jira_search", ["jql": .text("{pr_url}")])], output: "{a}")) != nil, "field unknown without the event")
        check(RoutineScripts.problem(script([step("a", "jira_search", ["jql": .text("{pr_url}")])], output: "{a}"), fields: ["pr_url"]) == nil, "field known with the event")
        check(RoutineScripts.problem(script((0...RoutineScripts.maxSteps).map { step("s\($0)", "jira_search") }))?.contains("at most") == true, "too many steps")
    }),

    ("script: steps run in order, a step's result reaches the later ones, and keep, drop and limit cut by line", {
        var calls: [String] = []
        let steps = [step("tickets", "jira_search", ["jql": .text("updated >= {yesterday}"), "limit": .number(10)], keep: "^QDLY|^ACME", drop: "Done", limit: 2),
                     step("first", "jira_issue", ["key": .text("{tickets}")])]
        let result = RoutineScripts.run(script(steps, output: "{date}\n{tickets}\n--\n{first}"), context: ["date": "2026-11-16", "yesterday": "2026-11-15"]) { tool, args in
            calls.append("\(tool) \(args.keys.sorted().map { "\($0)=\(args[$0] ?? "")" }.joined(separator: ","))")
            return tool == "jira_search" ? "ACME-1 open\nnoise\nACME-2 Done\nACME-3 open\nACME-4 open" : "detail"
        }
        check(result.failure == nil, "\(result.failure ?? "")")
        check(calls == ["jira_search jql=updated >= 2026-11-15,limit=10", "jira_issue key=ACME-1 open\nACME-3 open"], "\(calls)")
        check(result.output == "2026-11-16\nACME-1 open\nACME-3 open\n--\ndetail", result.output)
        check(result.steps.map(\.id) == ["tickets", "first"] && result.steps[0].rawCharacters > result.steps[0].characters, "sizes")
    }),

    ("script: a failing step, a result without what it expects, or every step empty makes the script fail", {
        let one = script([step("tickets", "jira_search")])
        let thrown = RoutineScripts.run(one, context: [:]) { _, _ in throw MCPToolError("Jira is not set up") }
        check(thrown.failure?.contains("Jira is not set up") == true && thrown.output.isEmpty, "throws")
        let expecting = RoutineScripts.run(script([step("tickets", "jira_search", expect: "^Tickets")]), context: [:]) { _, _ in "Something else" }
        check(expecting.failure?.contains("no longer answers") == true, "expect")
        check(RoutineScripts.run(script([step("tickets", "jira_search", expect: "^Tickets")]), context: [:]) { _, _ in "Tickets\nACME-1" }.failure == nil, "expect met")
        let empty = RoutineScripts.run(one, context: [:]) { _, _ in "  \n" }
        check(empty.failure == "Every step came back empty.", "empty")
        check(RoutineScripts.run(script([step("tickets", "jira_search")], nonEmpty: false), context: [:]) { _, _ in "" }.failure == nil, "empty is fine when allowed")
        let tolerated = RoutineScripts.run(script([step("a", "jira_search", optional: true), step("b", "jira_issue")], output: "[{a}] {b}"), context: [:]) { tool, _ in
            if tool == "jira_search" { throw MCPToolError("down") }
            return "ok"
        }
        check(tolerated.failure == nil && tolerated.output == "[] ok", "an optional step may fail: \(tolerated.output)")
    }),

    ("script: today's date and the weekday are built in", {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 5))!
        let values = RoutineScripts.builtinValues(now: monday, calendar: calendar)
        check(values == ["date": "2026-11-16", "yesterday": "2026-11-15", "weekday": "Monday", "time": "09:05"], "\(values)")
    }),

    ("script: what a script may call is read-only on the server too, and nothing that writes is on the list", {
        let tools = RoutineScriptRunner.tools()
        check(Set(tools.keys) == RoutineScripts.allowedTools, "every allowed tool exists: \(RoutineScripts.allowedTools.subtracting(tools.keys))")
        check(tools.values.allSatisfy(\.readOnly), "all read only")
        let none = Result<MeetingStore, Error>.failure(MCPToolError(""))
        let github = MCPServer.githubTools(none)
        let all = MCPServer.meetingTools(none) + github + MCPServer.agentTools(none, github: github) + MCPServer.topicTools() + MCPServer.resumeTools(none)
            + MCPServer.noticeTools() + MCPServer.reminderTools() + MCPServer.routineTools() + MCPServer.assistantTools() + MCPServer.briefTools()
        check(all.filter { !$0.readOnly }.allSatisfy { !RoutineScripts.allowedTools.contains($0.name) }, "no writing tool is allowed")
    }),

    ("determinism: the digest counts the calls, what a script could make and the characters, and keeps the last answer", {
        let digest = Determinism.digest(items: [
            item(.user("Brief me")),
            item(.tool(name: "mcp__worktime__jira_search", summary: "", detail: "{\n  \"jql\": \"assignee = currentUser()\"\n}", result: String(repeating: "x", count: 1000), isError: false, auto: true)),
            item(.tool(name: "Bash", summary: "", detail: "git status", result: "clean", isError: false, auto: true)),
            item(.text("First thoughts")),
            item(.text("Three tickets are open.")),
        ])
        check(digest.toolCalls == 2 && digest.readCalls == 1, "\(digest.toolCalls) \(digest.readCalls)")
        check(digest.resultCharacters == 1005, "\(digest.resultCharacters)")
        check(digest.answer == "Three tickets are open.", "answer")
        check(digest.text.contains("1. jira_search") && digest.text.contains("(1000 characters)") && digest.text.contains("Final answer:"), digest.text)
        check(digest.text.count < 1500, "the long result is clipped")
        check(Determinism.worthAnalysing(digest) && !Determinism.worthAnalysing(RunDigest()), "worth analysing")
    }),

    ("determinism: the analysis prompt carries the run, the tools and the event's fields, and says what is never allowed", {
        let digest = Determinism.digest(items: [item(.user("go")), item(.tool(name: "mcp__worktime__github_prs", summary: "", detail: "", result: "PR 1", isError: false, auto: true))])
        let tools = [ScriptToolInfo(name: "github_prs", summary: "The user's pull requests", arguments: ["state"])]
        let plain = Determinism.analysisPrompt(routine: routine(), digest: digest, tools: tools)
        check(plain.contains("Brief me on my tickets") && plain.contains("1. github_prs") && plain.contains("- github_prs(state): The user's pull requests"), "run and tools")
        check(plain.contains("{data}") && plain.contains("Never plan to post, approve, merge, comment or send"), "rules")
        let automation = Determinism.analysisPrompt(routine: routine(trigger: AutomationTrigger(kind: .reviewRequested)), digest: digest, tools: tools)
        check(automation.contains("{pr_url}"), "event fields")
    }),

    ("determinism: a proposal is read from a fenced answer, and one that cannot be saved is refused", {
        let hybrid = """
            Here you go:
            ```json
            {"mode": "hybrid", "summary": "Fetching is fixed.", "replaces": ["the search"], "keeps": ["the summary"],
             "script": {"steps": [{"id": "tickets", "tool": "jira_search", "args": {"jql": "assignee = currentUser()", "limit": 20}, "keep": "^ACME"}], "output": "{tickets}"},
             "prompt": "Summarise:\\n{data}"}
            ```
            """
        guard case .success(let proposal) = Determinism.parse(hybrid) else { return check(false, "parses") }
        check(proposal.mode == .hybrid && proposal.replaces == ["the search"] && proposal.script?.steps.first?.limit == nil, "fields")
        check(proposal.script?.steps.first?.args["limit"] == .number(20) && proposal.script?.steps.first?.keep == "^ACME", "step")
        check(Determinism.problem(proposal) == nil, "valid")

        var noData = proposal
        noData.prompt = "Summarise it"
        check(Determinism.problem(noData)?.contains("{data}") == true, "a hybrid prompt needs the data")
        var noScript = proposal
        noScript.script = nil
        check(Determinism.problem(noScript) == "The proposal has no script.", "no script")
        var writing = proposal
        writing.script = script([step("a", "create_routine")])
        check(Determinism.problem(writing)?.contains("not allowed") == true, "a writing tool")

        guard case .success(let none) = Determinism.parse("{\"mode\": \"none\", \"summary\": \"All judgement.\"}") else { return check(false, "none parses") }
        check(none.mode == .none && Determinism.problem(none) == nil && Determinism.plan(from: none, version: 1, savedTokens: 0) == nil, "none makes no plan")
        guard case .failure = Determinism.parse("no json here") else { return check(false, "prose fails") }
        guard case .failure = Determinism.parse("{\"mode\": \"maybe\"}") else { return check(false, "unknown mode fails") }
    }),

    ("determinism: the saving is the whole run for a script and the fetching that was filtered away for a hybrid", {
        var digest = RunDigest()
        digest.totalCharacters = 8000
        digest.resultCharacters = 6000
        digest.readCalls = 2
        check(Determinism.estimatedTokens(mode: .script, digest: digest, outputCharacters: 500) == 2000, "script")
        check(Determinism.estimatedTokens(mode: .hybrid, digest: digest, outputCharacters: 2000) == 1000 + 300, "hybrid")
        check(Determinism.estimatedTokens(mode: .hybrid, digest: digest, outputCharacters: 9000) == 300, "never negative")
        check(Determinism.savedText(2400) == "2.4k" && Determinism.savedText(90) == "90", "text")
    }),

    ("determinism: a routine with a trusted script runs it, every Nth run the agent runs in full, and one that failed runs as the agent", {
        check(Determinism.choose(nil, every: 10) == (.ai, false), "no plan")
        check(Determinism.choose(plan, every: 10) == (.hybrid, false), "hybrid")
        var script = plan
        script.mode = .script
        check(Determinism.choose(script, every: 10) == (.script, false), "script")
        script.runsSinceAI = 8
        check(Determinism.choose(script, every: 10) == (.script, false), "the ninth is still the script")
        script.runsSinceAI = 9
        check(Determinism.choose(script, every: 10) == (.ai, true), "the tenth is the agent's, to compare")
        check(Determinism.choose(script, every: 0) == (.script, false), "never compare")
        script.needsRecompile = true
        check(Determinism.choose(script, every: 0) == (.ai, false), "needs recompiling")
    }),

    ("determinism: a failing script falls back to the agent, an empty one too, and a hybrid gets the data in its prompt", {
        let failed = ScriptResult(output: "", steps: [], failure: "Step tickets (jira_search) failed: down")
        check(Determinism.decide(failed, plan: plan) == .fallBack(reason: "Step tickets (jira_search) failed: down"), "failure")
        check(Determinism.decide(ScriptResult(output: "ACME-1", steps: [], failure: nil), plan: plan) == .hybrid(prompt: "Summarise:\nACME-1"), "hybrid")
        var onlyScript = plan
        onlyScript.mode = .script
        check(Determinism.decide(ScriptResult(output: "ACME-1", steps: [], failure: nil), plan: onlyScript) == .script(output: "ACME-1"), "script")
        var broken = plan
        broken.prompt = "No place for it"
        guard case .fallBack = Determinism.decide(ScriptResult(output: "x", steps: [], failure: nil), plan: broken) else { return check(false, "a prompt without {data} falls back") }
    }),

    ("determinism: scripted runs are counted with what they saved, a compared run restarts the count, a failure asks for a recompile", {
        var counted = Determinism.counted(plan, mode: .hybrid, sampled: false, failure: nil)
        counted = Determinism.counted(counted, mode: .script, sampled: false, failure: nil)
        check(counted.runsSinceAI == 2 && counted.savedTotal == 1800 && !counted.needsRecompile, "\(counted)")
        counted = Determinism.counted(counted, mode: .ai, sampled: true, failure: nil)
        check(counted.runsSinceAI == 0 && counted.savedTotal == 1800, "compared")
        counted = Determinism.counted(counted, mode: .ai, sampled: false, failure: "Every step came back empty.")
        check(counted.needsRecompile && counted.reason == "Every step came back empty." && counted.runsSinceAI == 0, "failed")
        check(Determinism.counted(plan, mode: .ai, sampled: false, failure: nil) == plan, "an agent run that was not compared changes nothing")
    }),

    ("determinism: a proposal becomes a plan with its version, keeping what the old one saved", {
        let proposal = DeterminismProposal(mode: .hybrid, summary: "s", script: script([step("tickets", "jira_search")]), prompt: "Do {data}")
        var old = plan
        old.savedTotal = 5000
        let made = Determinism.plan(from: proposal, version: 3, savedTokens: 700, keeping: old)
        check(made == DeterministicPlan(mode: .hybrid, version: 3, prompt: "Do {data}", savedTokens: 700, savedTotal: 5000), "\(String(describing: made))")
        let wholly = Determinism.plan(from: DeterminismProposal(mode: .script, summary: "s", script: script([step("t", "jira_search")]), prompt: "ignored"), version: 1, savedTokens: 1)
        check(wholly?.mode == .script && wholly?.prompt == nil, "a script has no prompt")
    }),

    ("determinism: compile_routine's arguments become a proposal, and a bad mode or script is refused", {
        let json = RoutineScripts.encode(script([step("tickets", "jira_search")]))
        guard case .success(let proposal) = Determinism.proposal(from: RoutineCompile(mode: "hybrid", script: json, prompt: "Do {data}")) else { return check(false, "valid") }
        check(proposal.mode == .hybrid && proposal.prompt == "Do {data}" && Determinism.problem(proposal) == nil, "proposal")
        guard case .failure = Determinism.proposal(from: RoutineCompile(mode: "none", script: json, prompt: nil)) else { return check(false, "none is refused") }
        guard case .failure = Determinism.proposal(from: RoutineCompile(mode: "script", script: "{", prompt: nil)) else { return check(false, "bad script") }
        check(Determinism.briefIntro(routine()).contains("compile_routine") && Determinism.briefIntro(routine()).contains("r1"), "brief intro")
    }),

    ("determinism: the run's second line says how it was done, what it saved and when the script needs recompiling", {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ mode: RunMode?, saved: Int?) -> String {
            Routines.lastRunText(RoutineRun(started: now, finished: now, status: .done, mode: mode, savedTokens: saved), now: now)
        }
        check(!text(.ai, saved: nil).contains("\u{00B7}") && !text(nil, saved: nil).contains("\u{00B7}"), "an agent run says nothing more")
        check(text(.script, saved: 2400).hasSuffix("\u{00B7} script, ~2.4k tokens saved"), text(.script, saved: 2400))
        check(text(.hybrid, saved: 0).hasSuffix("\u{00B7} hybrid"), text(.hybrid, saved: 0))
        var needing = plan
        needing.needsRecompile = true
        check(Routines.detail(routine(determinism: needing), now: now).hasSuffix("script needs recompiling"), "recompile")
        check(!Routines.detail(routine(determinism: plan), now: now).contains("recompiling"), "trusted")
    }),

    ("determinism: a routine with a plan survives the file, and one saved before plans existed still reads", {
        var withPlan = routine(determinism: plan)
        withPlan.lastRun = RoutineRun(started: Date(timeIntervalSince1970: 5), finished: Date(timeIntervalSince1970: 9), status: .done, mode: .hybrid, savedTokens: 900)
        let decoded = Routines.decode(Routines.encode([withPlan]))
        check(decoded == [withPlan], "round trip")
        let old = routine()
        let data = Routines.encode([old])
        var object = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        object[0].removeValue(forKey: "determinism")
        object[0].removeValue(forKey: "analyzed")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        check(Routines.decode(stripped).first?.determinism == nil && Routines.decode(stripped).count == 1, "old file")
    }),

    ("determinism: scripts are kept as versions beside the routine, and a proposal waits in its folder until it is cleared", {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RoutineScriptFiles(root: root)
        let first = script([step("tickets", "jira_search")]), second = script([step("tickets", "jira_search", limit: 3)])
        check(files.versions("r1").isEmpty && files.load("r1", version: 1) == nil, "empty")
        check(try files.save(first, for: "r1") == 1 && files.save(second, for: "r1") == 2, "numbered")
        check(files.versions("r1") == [1, 2] && files.load("r1", version: 1) == first && files.load("r1", version: 2) == second, "both kept")
        check(files.versions("other").isEmpty, "per routine")

        let pending = PendingProposal(proposal: DeterminismProposal(mode: .script, summary: "s", script: first), digest: RunDigest(text: "run", readCalls: 1), created: Date(timeIntervalSince1970: 7))
        files.savePending(pending, for: "r1")
        check(files.pending(for: "r1") == pending, "pending")
        check(files.versions("r1") == [1, 2], "the proposal is not a version")
        files.clearPending(for: "r1")
        check(files.pending(for: "r1") == nil, "cleared")
        files.delete("r1")
        check(files.versions("r1").isEmpty, "deleted")
    }),

    ("determinism: a script can be run by name against the server's tools, and one the server does not offer fails", {
        let result = RoutineScripts.run(script([step("a", "get_meeting", ["id": .text("x")])]), context: [:]) { name, _ in
            guard RoutineScriptRunner.tools()[name] != nil else { throw MCPToolError("\(name) is not available to a script.") }
            return "ok"
        }
        check(result.failure == nil, "\(result.failure ?? "")")
        let missing = RoutineScripts.run(script([step("a", "get_meeting")]), context: [:]) { name, _ in throw MCPToolError("\(name) is not available to a script.") }
        check(missing.failure?.contains("not available") == true, "unavailable")
    }),
]
