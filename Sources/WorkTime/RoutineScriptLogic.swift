import Foundation

/// A value in a script step's arguments.
enum ScriptArg: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .number(let number): try container.encode(number)
        case .flag(let flag): try container.encode(flag)
        }
    }

    func value(filling fill: (String) -> String) -> Any {
        switch self {
        case .text(let text): fill(text)
        case .number(let number): number == number.rounded() ? Int(number) : number
        case .flag(let flag): flag
        }
    }
}

/// The deterministic part of a routine: read-only tool calls in order, each result optionally filtered, then an output template.
/// It is data, not code: it can only call the tools in `RoutineScripts.allowedTools`, so it can never post, approve, merge or send.
struct RoutineScript: Codable, Equatable, Sendable {
    struct Step: Codable, Equatable, Sendable {
        var id: String
        var tool: String
        var args: [String: ScriptArg] = [:]
        /// Only the lines of the result that match, drop those that match, and at most this many lines.
        var keep: String?
        var drop: String?
        var limit: Int?
        /// A pattern the raw result has to contain, to notice a tool that now answers differently.
        var expect: String?
        /// A failing step leaves its result empty instead of failing the script.
        var optional: Bool?

        init(id: String, tool: String, args: [String: ScriptArg] = [:], keep: String? = nil, drop: String? = nil, limit: Int? = nil,
             expect: String? = nil, optional: Bool? = nil) {
            self.id = id
            self.tool = tool
            self.args = args
            self.keep = keep
            self.drop = drop
            self.limit = limit
            self.expect = expect
            self.optional = optional
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            tool = try container.decode(String.self, forKey: .tool)
            args = try container.decodeIfPresent([String: ScriptArg].self, forKey: .args) ?? [:]
            keep = try container.decodeIfPresent(String.self, forKey: .keep)
            drop = try container.decodeIfPresent(String.self, forKey: .drop)
            limit = try container.decodeIfPresent(Int.self, forKey: .limit)
            expect = try container.decodeIfPresent(String.self, forKey: .expect)
            optional = try container.decodeIfPresent(Bool.self, forKey: .optional)
        }
    }

    var steps: [Step]
    /// The script's answer, with `{step id}` and the placeholders of `RoutineScripts.builtins` and the event's fields.
    var output: String
    /// False when an empty result of every step is a normal answer; by default it makes the script fall back to the agent.
    var nonEmpty: Bool?
}

struct ScriptResult: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var id: String
        var ok: Bool
        var rawCharacters: Int
        var characters: Int
    }

    var output = ""
    var steps: [Step] = []
    var failure: String?

    var rawCharacters: Int { steps.reduce(0) { $0 + $1.rawCharacters } }
}

enum RoutineScripts {
    static let maxSteps = 12
    static let maxOutput = 60_000
    static let maxSize = 30_000
    static let builtins = ["date", "yesterday", "weekday", "time"]

    /// The tools a script may call: the ones that only read, and answer from the app's own files or a service, never through the
    /// app's inbox. Each is checked against the server's read-only flag too.
    static let allowedTools: Set<String> = [
        "attention", "github_prs", "github_pr", "github_needs_attention", "resume_context", "activity_context", "time_report",
        "search_meetings", "get_meeting", "recent_meetings", "jira_issue", "jira_search", "slack_thread", "slack_search",
    ]

    static func encode(_ script: RoutineScript) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(script)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func decode(_ text: String) -> Result<RoutineScript, NoticeError> {
        do {
            return .success(try JSONDecoder().decode(RoutineScript.self, from: Data(text.utf8)))
        } catch {
            return .failure(NoticeError("The script is not valid: \(describe(error))"))
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, _): return "\(key.stringValue) is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return "it could not be read."
        }
    }

    static func placeholders(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in Range(match.range(at: 1), in: text).map { String(text[$0]) } }
    }

    static func fill(_ template: String, values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#) else { return template }
        var text = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: template) else { continue }
            text.replaceSubrange(whole, with: values[String(template[name])] ?? "")
        }
        return text
    }

    /// Why the script cannot be saved, nil when it can. `fields` are the placeholders an automation's event offers.
    static func problem(_ script: RoutineScript, tools: Set<String> = allowedTools, fields: Set<String> = []) -> String? {
        guard !script.steps.isEmpty else { return "A script needs at least one step." }
        guard script.steps.count <= maxSteps else { return "A script has at most \(maxSteps) steps." }
        guard encode(script).utf8.count <= maxSize else { return "The script is too long." }
        var known = Set(builtins).union(fields), ids = Set<String>()
        for step in script.steps {
            guard step.id.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil else {
                return "Step id \u{201C}\(step.id)\u{201D} must be lower case letters, digits and underscores."
            }
            guard !ids.contains(step.id), !builtins.contains(step.id), !fields.contains(step.id) else { return "Step id \(step.id) is used twice or is a placeholder." }
            guard tools.contains(step.tool) else {
                return "Step \(step.id): \(step.tool) is not allowed in a script. Only these read-only tools are: \(tools.sorted().joined(separator: ", "))."
            }
            for pattern in [step.keep, step.drop, step.expect].compactMap({ $0 }) where (try? NSRegularExpression(pattern: pattern)) == nil {
                return "Step \(step.id): \u{201C}\(pattern)\u{201D} is not a valid regular expression."
            }
            if let limit = step.limit, limit < 1 { return "Step \(step.id): limit must be at least 1." }
            for case .text(let text) in step.args.values {
                if let unknown = placeholders(in: text).first(where: { !known.contains($0) }) { return "Step \(step.id) uses {\(unknown)}, which is not known before it." }
            }
            ids.insert(step.id)
            known.insert(step.id)
        }
        guard !script.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "The script needs an output." }
        if let unknown = placeholders(in: script.output).first(where: { !known.contains($0) }) { return "The output uses {\(unknown)}, which is not a step or a placeholder." }
        return nil
    }

    /// The values every script can use: today's date and the like.
    static func builtinValues(now: Date, calendar: Calendar = .current) -> [String: String] {
        func day(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        return ["date": day(now), "yesterday": day(yesterday), "weekday": RoutineRequests.weekdayNames[calendar.component(.weekday, from: now) - 1].capitalized,
                "time": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)]
    }

    static func filtered(_ text: String, step: RoutineScript.Step) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let keep = step.keep { lines = lines.filter { $0.range(of: keep, options: .regularExpression) != nil } }
        if let drop = step.drop { lines = lines.filter { $0.range(of: drop, options: .regularExpression) == nil } }
        if let limit = step.limit { lines = Array(lines.prefix(limit)) }
        return lines.joined(separator: "\n")
    }

    /// Runs the steps with `call`, which answers a tool call with its text. A failing step, a result without what it `expect`s, or
    /// nothing at all from every step is a failure, so the caller can fall back to the agent.
    static func run(_ script: RoutineScript, context: [String: String], call: (String, [String: Any]) throws -> String) -> ScriptResult {
        var values = context, result = ScriptResult()
        for step in script.steps {
            let args = step.args.mapValues { arg in arg.value { fill($0, values: values) } }
            do {
                let raw = try call(step.tool, args)
                if let expect = step.expect, raw.range(of: expect, options: .regularExpression) == nil {
                    result.steps.append(.init(id: step.id, ok: false, rawCharacters: raw.count, characters: 0))
                    result.failure = "Step \(step.id) (\(step.tool)) no longer answers with /\(expect)/."
                    return result
                }
                let text = filtered(raw, step: step)
                values[step.id] = text
                result.steps.append(.init(id: step.id, ok: true, rawCharacters: raw.count, characters: text.count))
            } catch {
                result.steps.append(.init(id: step.id, ok: false, rawCharacters: 0, characters: 0))
                guard step.optional == true else {
                    result.failure = "Step \(step.id) (\(step.tool)) failed: \(error.localizedDescription)"
                    return result
                }
                values[step.id] = ""
            }
        }
        let gathered = script.steps.filter { $0.optional != true }
        if script.nonEmpty != false, !gathered.isEmpty,
           gathered.allSatisfy({ (values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            result.failure = "Every step came back empty."
            return result
        }
        let output = fill(script.output, values: values)
        result.output = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n\u{2026}" : output
        return result
    }
}
