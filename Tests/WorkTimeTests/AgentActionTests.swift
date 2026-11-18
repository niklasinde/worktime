import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fence = "```"

private func block(_ lines: String...) -> String { ([fence + AgentActions.info] + lines + [fence]).joined(separator: "\n") }

private func actions(_ segments: [AgentActions.Segment]) -> [AgentAction] {
    segments.compactMap { if case .action(let action) = $0 { action } else { nil } }
}

private func entry(_ name: String, broken: Bool = false) -> AssistantEntry {
    AssistantEntry(workspace: "work", role: AssistantRole(slug: Assistants.slug(name), name: name, summary: "s", body: "b",
                                                          problems: broken ? [AssistantProblem(line: nil, message: "bad")] : []))
}

private let sample = block("title: Check the five points on pull 12", "assistant: Reviewer", "prompt: |", "  Review acme-com/orbit.api#12.", "", "    Report one verdict.")

let agentActionTests: [(name: String, run: () throws -> Void)] = [
    ("action: a block between prose becomes buttons with its title, assistant and the prompt as written", {
        let segments = AgentActions.segments("I can have the Reviewer look.\n\n" + sample + "\n\nTell me.")
        check(segments.count == 3, "\(segments)")
        guard case .markdown(let before) = segments[0], case .markdown(let after) = segments[2] else { return check(false, "markdown around") }
        check(before == "I can have the Reviewer look.\n" && after == "\nTell me.", "\(before)|\(after)")
        let action = actions(segments)[0]
        check(action.title == "Check the five points on pull 12" && action.assistant == "Reviewer", "\(action)")
        check(action.prompt == "Review acme-com/orbit.api#12.\n\n  Report one verdict.", action.prompt)
    }),
    ("action: the title falls back to the prompt's first line, quotes are dropped and a long title is clipped", {
        let bare = actions(AgentActions.segments(block("prompt: Look at the failing check.\nThen say why.")))[0]
        check(bare.title == "Look at the failing check." && bare.prompt == "Look at the failing check.\nThen say why." && bare.assistant == nil, "\(bare)")
        let quoted = actions(AgentActions.segments(block("title: \"Quoted\"", "prompt: do it")))[0]
        check(quoted.title == "Quoted", quoted.title)
        let long = actions(AgentActions.segments(block("title: " + String(repeating: "x", count: 300), "prompt: do it")))[0]
        check(long.title.count == AgentActions.titleLimit && long.title.hasSuffix("\u{2026}"), "\(long.title.count)")
    }),
    ("action: a block with no prompt, too long a prompt or no closing fence stays Markdown for the code it is", {
        for text in [block("title: Nothing"), block("prompt: " + String(repeating: "x", count: AgentActions.promptLimit + 1)),
                     fence + AgentActions.info + "\nprompt: still being written"] {
            let segments = AgentActions.segments(text)
            check(actions(segments).isEmpty, "no action in \(text.prefix(40))")
            check(segments == [.markdown(text)], "kept as written: \(segments)")
        }
    }),
    ("action: several blocks give one action each in order, and the same block twice gets its own id", {
        let found = actions(AgentActions.segments(sample + "\ntext\n" + block("prompt: other") + "\n" + sample))
        check(found.count == 3 && found[0].title != found[1].title, "\(found.map(\.title))")
        check(Set(found.map(\.id)).count == 3, "ids \(found.map(\.id))")
        check(found[2].id == found[0].id + "-1", "\(found[2].id)")
    }),
    ("action: a block shown inside another code fence is an example, not a button", {
        let text = "Write it like this:\n\n````markdown\n" + sample + "\n````\n\nThen:\n" + block("prompt: real")
        let found = actions(AgentActions.segments(text))
        check(found.count == 1 && found[0].prompt == "real", "\(found)")
    }),
    ("action: the id is the same wherever the reply sits and changes with the instructions", {
        let first = actions(AgentActions.segments("a\n" + sample))[0], again = actions(AgentActions.segments("something else first\n\n" + sample))[0]
        check(first.id == again.id, "\(first.id) \(again.id)")
        let edited = actions(AgentActions.segments(block("title: Check the five points on pull 12", "prompt: different")))[0]
        check(edited.id != first.id, "edited")
        check(AgentActions.id(title: "a", prompt: "b") == AgentActions.id(title: "a", prompt: "b") && AgentActions.id(title: "ab", prompt: "") != AgentActions.id(title: "a", prompt: "b"), "hash")
    }),
    ("action: a key written inside the indented prompt does not end it, one at the start of a line does", {
        let inside = actions(AgentActions.segments(block("prompt: |", "  title: not a key", "  more")))[0]
        check(inside.prompt == "title: not a key\nmore", inside.prompt)
        let after = actions(AgentActions.segments(block("prompt: |", "  go", "assistant: Reviewer")))[0]
        check(after.prompt == "go" && after.assistant == "Reviewer", "\(after)")
    }),
    ("action: the assistant is found by name, key or file name, and only when it works", {
        let reviewer = entry("Reviewer"), developer = entry("Developer"), broken = entry("Support", broken: true)
        let all = [reviewer, developer, broken]
        check(AgentActions.suggested("reviewer", in: all) == reviewer, "name")
        check(AgentActions.suggested("Developer assistant", in: all) == developer, "suffix")
        check(AgentActions.suggested(reviewer.key, in: all) == reviewer, "key")
        check(AgentActions.suggested("Support", in: all) == nil && AgentActions.suggested("Nobody", in: all) == nil && AgentActions.suggested(nil, in: all) == nil, "none")
    }),
    ("action: a dismissed action is hidden for that agent only, and stays hidden after encoding", {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let book = ReviewDismissedBook.record(AgentActionOutcomes.key(agent: "a", action: "x"), date: date, in: [:])
        check(AgentActionOutcomes.isDismissed(agent: "a", action: "x", in: book), "dismissed")
        check(!AgentActionOutcomes.isDismissed(agent: "b", action: "x", in: book) && !AgentActionOutcomes.isDismissed(agent: "a", action: "y", in: book), "others stay")
        check(AgentActionOutcomes.isDismissed(agent: "a", action: "x", in: ReviewDismissedBook.decode(ReviewDismissedBook.encode(book))), "kept")
    }),
    ("action: clicked actions are kept per agent and action, the oldest dropped past the limit, and survive encoding", {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var book = AgentActionOutcomes.record(AgentActionOutcome(assistant: nil, name: nil, date: date), agent: "a", action: "x", in: [:])
        book = AgentActionOutcomes.record(AgentActionOutcome(assistant: "assistant:work:reviewer", name: "Reviewer", date: date), agent: "b", action: "x", in: book)
        check(book[AgentActionOutcomes.key(agent: "a", action: "x")]?.label == "Sent to this agent", "here")
        check(book[AgentActionOutcomes.key(agent: "b", action: "x")]?.label == "Sent to Reviewer", "assistant")
        check(AgentActionOutcomes.decode(AgentActionOutcomes.encode(book)) == book, "round trip")
        check(AgentActionOutcomes.decode(nil).isEmpty && AgentActionOutcomes.decode(Data("nope".utf8)).isEmpty, "bad data")
        var many: AgentActionOutcomes.Book = [:]
        for index in 0..<(AgentActions.keepLimit + 5) {
            many = AgentActionOutcomes.record(AgentActionOutcome(assistant: nil, name: nil, date: date.addingTimeInterval(Double(index))), agent: "a", action: "\(index)", in: many)
        }
        check(many.count == AgentActions.keepLimit && many[AgentActionOutcomes.key(agent: "a", action: "0")] == nil
              && many[AgentActionOutcomes.key(agent: "a", action: "\(AgentActions.keepLimit + 4)")] != nil, "\(many.count)")
    }),
]
