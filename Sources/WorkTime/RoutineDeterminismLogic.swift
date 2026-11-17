import Foundation

/// How a run of a routine was done: by the agent alone, by a script that gathered the data for a shorter prompt, or by the script alone.
enum RunMode: String, Codable, Sendable {
    case ai, hybrid, script

    var label: String {
        switch self {
        case .ai: "AI"
        case .hybrid: "hybrid"
        case .script: "script"
        }
    }
}

/// What a routine runs in place of its whole prompt: a script saved beside it, and for a hybrid the shorter prompt that takes the
/// script's output where it says `{data}`.
struct DeterministicPlan: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case script, hybrid }

    var mode: Mode
    var version: Int
    var prompt: String?
    var runsSinceAI = 0
    var needsRecompile = false
    var reason: String?
    /// What one scripted run is estimated to save, and what the scripted runs saved in all.
    var savedTokens = 0
    var savedTotal = 0
}

/// What the analysis of a run proposes.
struct DeterminismProposal: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case script, hybrid, none }

    var mode: Mode
    var summary: String
    var replaces: [String]
    var keeps: [String]
    var script: RoutineScript?
    var prompt: String?

    init(mode: Mode, summary: String, replaces: [String] = [], keeps: [String] = [], script: RoutineScript? = nil, prompt: String? = nil) {
        self.mode = mode
        self.summary = summary
        self.replaces = replaces
        self.keeps = keeps
        self.script = script
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        replaces = try container.decodeIfPresent([String].self, forKey: .replaces) ?? []
        keeps = try container.decodeIfPresent([String].self, forKey: .keeps) ?? []
        script = try container.decodeIfPresent(RoutineScript.self, forKey: .script)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    }
}

/// A tool as the analysis is told about it.
struct ScriptToolInfo: Equatable, Sendable {
    var name: String
    var summary: String
    var arguments: [String]
}

/// A run's transcript boiled down for the analysis.
struct RunDigest: Codable, Equatable, Sendable {
    var text = ""
    var toolCalls = 0
    var readCalls = 0
    var resultCharacters = 0
    var totalCharacters = 0
    var answer: String?
}

enum Determinism {
    static let dataPlaceholder = "{data}"
    static let fullRunEveryKey = "routineFullRunEvery"
    static let defaultFullRunEvery = 10
    static let autoAnalyzeKey = "routineAutoAnalyze"
    static let toolPrefix = "mcp__worktime__"
    static let tokensPerCall = 150
    static let digestResultLimit = 500
    static let digestDetailLimit = 300

    static func fullRunEvery(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: fullRunEveryKey) == nil ? defaultFullRunEvery : max(0, defaults.integer(forKey: fullRunEveryKey))
    }

    static func autoAnalyze(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoAnalyzeKey) as? Bool ?? true
    }

    // MARK: Looking at a run

    private static func clipped(_ text: String, to limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "\u{2026}" : line
    }

    static func toolName(_ name: String) -> String { name.hasPrefix(toolPrefix) ? String(name.dropFirst(toolPrefix.count)) : name }

    static func digest(items: [AgentItem]) -> RunDigest {
        var digest = RunDigest(), lines: [String] = []
        for item in items {
            switch item.kind {
            case .user(let text):
                lines.append("Prompt: " + clipped(text, to: 600))
                digest.totalCharacters += text.count
            case .text(let text):
                digest.answer = text
                digest.totalCharacters += text.count
            case .tool(let name, _, let detail, let result, let isError, _, _):
                digest.toolCalls += 1
                let base = toolName(name), size = result?.count ?? 0
                if RoutineScripts.allowedTools.contains(base) { digest.readCalls += 1 }
                digest.resultCharacters += size
                digest.totalCharacters += size + detail.count
                var line = "\(digest.toolCalls). \(base) \(clipped(detail, to: digestDetailLimit))"
                if let result { line += "\n   \u{2192} " + (isError ? "ERROR " : "") + clipped(result, to: digestResultLimit) + " (\(size) characters)" }
                lines.append(line)
            default: break
            }
        }
        if let answer = digest.answer { lines.append("Final answer:\n" + clipped(answer, to: 1500)) }
        digest.text = lines.joined(separator: "\n")
        return digest
    }

    /// Whether the run held a tool call a script could make; without one there is nothing to look for.
    static func worthAnalysing(_ digest: RunDigest) -> Bool { digest.readCalls > 0 }

    static func analysisPrompt(routine: Routine, digest: RunDigest, tools: [ScriptToolInfo]) -> String {
        let fields = routine.trigger.map { $0.kind.fields.map { "{\($0)}" }.joined(separator: " ") } ?? ""
        let toolLines = tools.map { "- \($0.name)(\($0.arguments.joined(separator: ", "))): \($0.summary)" }.joined(separator: "\n")
        return """
            You are looking at one run of the scheduled routine \u{201C}\(routine.name)\u{201D} in WorkTime, to find out which parts of it need no AI.

            The routine's prompt:
            \(routine.prompt)

            The run: the tool calls in order, each with the start of its result, and the final answer.
            \(digest.text)

            Decide for each step of the flow whether it is deterministic (a fixed fetch, filter, sort or formatting of data that depends only on \
            today's date\(routine.isAutomation ? " or the event" : "")) or judgement (summarising, ranking, deciding, drafting, anything that needs reading meaning).
            Answer with only one JSON object and no other text:
            {"mode": "script" | "hybrid" | "none", "summary": "one or two sentences", "replaces": ["steps the script does"], "keeps": ["steps the model still does"], "script": {...}, "prompt": "..."}
            - script: the whole flow is deterministic; the script's output is the answer. Omit prompt.
            - hybrid: the script gathers, filters and formats the data, and a shorter prompt does only the judgement part. The prompt must hold \
            \(dataPlaceholder), where the script's output goes, and must not tell the model to fetch what the script already did.
            - none: nothing is worth replacing, or the tools below cannot do it. Omit script and prompt; the summary says why.

            The script is data, not code:
            {"steps": [{"id": "prs", "tool": "github_prs", "args": {"state": "open"}, "keep": "regex", "drop": "regex", "limit": 20, "expect": "regex", "optional": false}], \
            "output": "text with {prs} and {date}", "nonEmpty": true}
            Rules:
            - A step calls one of these read-only tools, and nothing else is allowed:
            \(toolLines)
            - Take the arguments from the calls above, and write a date as {date} or {yesterday}. Arguments are strings, numbers or booleans.
            - In argument strings and in the output, {date}, {yesterday}, {weekday}, {time}, the ids of the steps before it\
            \(fields.isEmpty ? "" : " and \(fields)") are filled in.
            - keep, drop and limit cut a result down by line. expect is a pattern the raw result always holds, such as its header line, to notice a tool that answers differently.
            - Steps that used other tools, such as a shell or a file read, stay with the model, so the mode is hybrid.
            - Never plan to post, approve, merge, comment or send anything.
            """
    }

    /// What an agent asking for the analysis is told before the analysis itself: to answer with compile_routine.
    static func briefIntro(_ routine: Routine) -> String {
        "Work out which parts of the routine \u{201C}\(routine.name)\u{201D} could run as a script, as described below, but instead of answering with the JSON object call "
            + "compile_routine with id \(routine.id), mode, script (the script as JSON text) and for a hybrid prompt. The user is asked to approve that call and sees the script. "
            + "When the mode would be none, tell the user why instead of calling it.\n\n"
    }

    /// The proposal `compile_routine` hands over.
    static func proposal(from compile: RoutineCompile) -> Result<DeterminismProposal, NoticeError> {
        guard let mode = DeterminismProposal.Mode(rawValue: compile.mode), mode != .none else { return .failure(NoticeError("mode must be script or hybrid.")) }
        switch RoutineScripts.decode(compile.script) {
        case .failure(let error): return .failure(error)
        case .success(let script): return .success(DeterminismProposal(mode: mode, summary: "Made by an agent.", script: script, prompt: compile.prompt))
        }
    }

    /// The proposal in the analysis' answer, which may come in a code fence or after a sentence.
    static func parse(_ text: String) -> Result<DeterminismProposal, NoticeError> {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return .failure(NoticeError("The analysis held no proposal."))
        }
        do {
            return .success(try JSONDecoder().decode(DeterminismProposal.self, from: Data(text[start...end].utf8)))
        } catch {
            return .failure(NoticeError("The proposal could not be read: \(error.localizedDescription)"))
        }
    }

    /// Why the proposal cannot be saved as a plan, nil when it can.
    static func problem(_ proposal: DeterminismProposal, fields: Set<String> = []) -> String? {
        switch proposal.mode {
        case .none: return nil
        case .script, .hybrid:
            guard let script = proposal.script else { return "The proposal has no script." }
            if let problem = RoutineScripts.problem(script, fields: fields) { return problem }
            if proposal.mode == .hybrid {
                guard let prompt = proposal.prompt, prompt.contains(dataPlaceholder) else { return "A hybrid needs a prompt with \(dataPlaceholder) in it." }
            }
            return nil
        }
    }

    /// What a scripted run is estimated to save: the model no longer pays for the whole run, or for fetching what the script filtered away.
    static func estimatedTokens(mode: DeterministicPlan.Mode, digest: RunDigest, outputCharacters: Int) -> Int {
        switch mode {
        case .script: return digest.totalCharacters / 4
        case .hybrid: return max(0, digest.resultCharacters - outputCharacters) / 4 + tokensPerCall * digest.readCalls
        }
    }

    static func plan(from proposal: DeterminismProposal, version: Int, savedTokens: Int, keeping old: DeterministicPlan? = nil) -> DeterministicPlan? {
        guard proposal.mode != .none else { return nil }
        return DeterministicPlan(mode: proposal.mode == .script ? .script : .hybrid, version: version, prompt: proposal.mode == .hybrid ? proposal.prompt : nil,
                                 savedTokens: savedTokens, savedTotal: old?.savedTotal ?? 0)
    }

    // MARK: Running

    /// How the next run is done. A routine whose script needs recompiling runs as the agent; so does every `every`th run, to
    /// see whether the script still does what the agent does (never when `every` is 0).
    static func choose(_ plan: DeterministicPlan?, every: Int) -> (mode: RunMode, sampled: Bool) {
        guard let plan, !plan.needsRecompile else { return (.ai, false) }
        if every > 0, plan.runsSinceAI + 1 >= every { return (.ai, true) }
        return (plan.mode == .script ? .script : .hybrid, false)
    }

    enum Decision: Equatable {
        case script(output: String)
        case hybrid(prompt: String)
        case fallBack(reason: String)
    }

    /// What to do with the script's result: use it, or run the agent as if there were no plan.
    static func decide(_ result: ScriptResult, plan: DeterministicPlan) -> Decision {
        if let failure = result.failure { return .fallBack(reason: failure) }
        switch plan.mode {
        case .script: return .script(output: result.output)
        case .hybrid:
            guard let prompt = plan.prompt, prompt.contains(dataPlaceholder) else { return .fallBack(reason: "The plan has no prompt for the output.") }
            return .hybrid(prompt: prompt.replacingOccurrences(of: dataPlaceholder, with: result.output))
        }
    }

    /// The plan after a run: counts the scripted runs and what they saved, restarts the count at a run the agent did to compare, and
    /// asks for a recompile when the script failed (in the run itself or beside a compared run).
    static func counted(_ plan: DeterministicPlan, mode: RunMode, sampled: Bool, failure: String?) -> DeterministicPlan {
        var plan = plan
        if let failure {
            plan.needsRecompile = true
            plan.reason = failure
        }
        switch mode {
        case .script, .hybrid:
            plan.runsSinceAI += 1
            plan.savedTotal += plan.savedTokens
        case .ai:
            if sampled { plan.runsSinceAI = 0 }
        }
        return plan
    }

    static func savedText(_ tokens: Int) -> String {
        tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
    }
}
