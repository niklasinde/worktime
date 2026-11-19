import Foundation

/// A next step an agent offers in its reply, written as a fenced block the app turns into buttons:
///
///     ```worktime-action
///     title: Check the five points
///     assistant: Reviewer
///     prompt: |
///       Review the five points on ...
///     ```
struct AgentAction: Equatable, Identifiable {
    /// The same for the same block wherever the reply sits, so a clicked button stays clicked after the session is loaded again.
    let id: String
    let title: String
    let assistant: String?
    let prompt: String
}

enum AgentActions {
    static let info = "worktime-action"
    static let titleLimit = 120
    /// What `send_to_agent` and its notification path accept.
    static let promptLimit = AgentInbox.textLimit
    static let keepLimit = 300

    enum Segment: Equatable {
        case markdown(String)
        case action(AgentAction)
        case review(ReviewDraft)
    }

    /// The reply's text in order: Markdown, and the action blocks that are complete and well formed. A block that is not stays
    /// in the Markdown, where it shows as the code it is, and so does one still being written.
    static func segments(_ text: String, actions: Bool = true) -> [Segment] {
        var segments: [Segment] = []
        var markdown: [String] = []
        var seen: [String: Int] = [:]
        var otherFence: String?
        let lines = text.components(separatedBy: "\n")
        var index = 0
        func flush() {
            let joined = markdown.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(joined)) }
            markdown = []
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = otherFence {
                if isClosing(trimmed, of: fence) { otherFence = nil }
                markdown.append(line)
            } else if let fence = opening(trimmed) {
                if fence.info == ReviewDrafts.info, let end = lines[(index + 1)...].firstIndex(where: { isClosing($0.trimmingCharacters(in: .whitespaces), of: fence.marker) }),
                   let draft = ReviewDrafts.parse(block: lines[(index + 1)..<end].joined(separator: "\n")) {
                    flush()
                    segments.append(.review(draft))
                    index = end
                } else if actions, fence.info == info, let end = lines[(index + 1)...].firstIndex(where: { isClosing($0.trimmingCharacters(in: .whitespaces), of: fence.marker) }),
                   let fields = fields(Array(lines[(index + 1)..<end])) {
                    flush()
                    let base = id(title: fields.title, prompt: fields.prompt)
                    let count = seen[base, default: 0]
                    seen[base] = count + 1
                    segments.append(.action(AgentAction(id: count == 0 ? base : "\(base)-\(count)", title: fields.title, assistant: fields.assistant, prompt: fields.prompt)))
                    index = end
                } else {
                    if fence.info != info || !actions { otherFence = fence.marker }
                    markdown.append(line)
                }
            } else {
                markdown.append(line)
            }
            index += 1
        }
        flush()
        return segments
    }

    static func opening(_ line: String) -> (marker: String, info: String)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let marker = String(line.prefix { $0 == first })
        guard marker.count >= 3 else { return nil }
        return (marker, line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
    }

    static func isClosing(_ line: String, of marker: String) -> Bool {
        guard let first = marker.first, line.count >= marker.count else { return false }
        return line.allSatisfy { $0 == first }
    }

    private static let keys = ["title", "assistant", "prompt"]

    /// The block's title, assistant and prompt; nil when there is no prompt or it is too long. The title falls back to the
    /// prompt's first line. The prompt runs to the end of the block, or to the next key written at the start of a line.
    static func fields(_ lines: [String]) -> (title: String, assistant: String?, prompt: String)? {
        var values: [String: [String]] = [:]
        var current: String?
        for line in lines {
            if let (key, rest) = keyLine(line) {
                current = key
                values[key] = block(rest) ? [] : [unquoted(rest)]
            } else if let current {
                values[current, default: []].append(line)
            }
        }
        let prompt = dedent(values["prompt"] ?? []).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= promptLimit else { return nil }
        let first = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let title = clipped((values["title"] ?? []).joined(separator: " ").trimmingCharacters(in: .whitespaces), fallback: first)
        let assistant = (values["assistant"] ?? []).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (title, assistant.isEmpty ? nil : assistant, prompt)
    }

    private static func keyLine(_ line: String) -> (key: String, rest: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].lowercased()
        guard keys.contains(key) else { return nil }
        return (key, String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func block(_ rest: String) -> Bool { ["|", ">", "|-", ">-", ""].contains(rest) }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func dedent(_ lines: [String]) -> String {
        let indent = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(indent, $0.prefix { $0 == " " }.count))) }.joined(separator: "\n")
    }

    static func clipped(_ title: String, fallback: String) -> String {
        let text = title.isEmpty ? fallback : title
        return text.count > titleLimit ? String(text.prefix(titleLimit - 1)) + "\u{2026}" : text
    }

    /// FNV-1a over the title and prompt, in hex.
    static func id(title: String, prompt: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (title + "\u{0}" + prompt).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// The assistant an action names, by key, name or file name; nil when it names none that exists and works.
    static func suggested(_ name: String?, in entries: [AssistantEntry]) -> AssistantEntry? {
        guard let name, case .success(let target)? = Assistants.resolve(name, in: entries) else { return nil }
        return entries.first { $0.key == target.key }
    }
}

/// Where a clicked action went.
struct AgentActionOutcome: Codable, Equatable {
    /// The assistant's key, nil for the agent that wrote the action.
    var assistant: String?
    var name: String?
    var date: Date

    var label: String { assistant == nil ? "Sent to this agent" : "Sent to \(name ?? "an assistant")" }
}

/// The actions already clicked, by agent and action, kept between runs of the app.
enum AgentActionOutcomes {
    typealias Book = [String: AgentActionOutcome]

    static func key(agent: String, action: String) -> String { agent + "|" + action }

    /// Dismissed actions reuse the reviews' dated book, under the same agent and action key.
    static func isDismissed(agent: String, action: String, in dismissed: ReviewDismissedBook.Book) -> Bool {
        dismissed[key(agent: agent, action: action)] != nil
    }

    static func record(_ outcome: AgentActionOutcome, agent: String, action: String, in book: Book) -> Book {
        var book = book
        book[key(agent: agent, action: action)] = outcome
        let extra = book.count - AgentActions.keepLimit
        if extra > 0 { for old in book.sorted(by: { $0.value.date < $1.value.date }).prefix(extra) { book[old.key] = nil } }
        return book
    }

    static func encode(_ book: Book) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(book)
    }

    static func decode(_ data: Data?) -> Book {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.flatMap { try? decoder.decode(Book.self, from: $0) } ?? [:]
    }
}
