import Foundation

/// One placeholder a template can use, with what it stands for.
struct PromptPlaceholder: Equatable, Sendable {
    let name: String
    let note: String
}

/// The prompts WorkTime writes for its agents, each kept as a Markdown file the user can edit. The built-in text is what a template
/// falls back to when no file holds one.
enum PromptTemplate: String, CaseIterable, Identifiable, Sendable {
    case reviewPR = "review-pr"
    case reviewSet = "review-set"
    case reviewSetSystem = "review-set-system"
    case reviewPRAsk = "review-pr-ask"
    case reviewSetAsk = "review-set-ask"
    case jiraAsk = "jira-ask"
    case reviewDraftFormat = "review-draft-format"
    case agentActions = "agent-actions"
    case agentReview = "agent-review"
    case agentReport = "agent-report"
    case agentWhere = "agent-where"
    case mainReportNote = "main-report-note"
    case unattendedRun = "unattended-run"
    case automationRun = "automation-run"
    case automationAskRun = "automation-ask-run"

    var id: String { rawValue }

    /// Raised when the built-in text changes in a way a file written earlier should be told about.
    var version: Int { 1 }

    var fileName: String { rawValue + ".md" }

    var title: String {
        switch self {
        case .reviewPR: "Review one pull request"
        case .reviewSet: "Review pull requests together"
        case .reviewSetSystem: "Pull request set: instructions"
        case .reviewPRAsk: "Review button: one pull request"
        case .reviewSetAsk: "Review button: several pull requests"
        case .jiraAsk: "Start button: Jira ticket"
        case .reviewDraftFormat: "Review draft format"
        case .agentActions: "Next steps as buttons"
        case .agentReview: "Drafting a review"
        case .agentReport: "Reporting to Main"
        case .agentWhere: "Where the agent's files live"
        case .mainReportNote: "Main: reports from agents"
        case .unattendedRun: "Scheduled runs"
        case .automationRun: "Runs started by an event"
        case .automationAskRun: "Runs that ask first"
        }
    }

    var summary: String {
        switch self {
        case .reviewPR: "The prompt waiting in a new agent for one pull request that was linked to a set."
        case .reviewSet: "The prompt waiting in a new agent for two or more pull requests that belong together."
        case .reviewSetSystem: "What a pull request set\u{2019}s agent is told about its pull requests and its folder."
        case .reviewPRAsk: "What the first button of an automation\u{2019}s question sends to the pull request\u{2019}s agent or the assistant."
        case .reviewSetAsk: "What the first button sends to one agent when the event names several pull requests."
        case .jiraAsk: "What the first button sends when the event is a Jira ticket."
        case .reviewDraftFormat: "The block an agent writes its review in, so the app can offer to post it with a click."
        case .agentActions: "Added to every agent: how to offer a next step as Do it here and Ask an assistant buttons."
        case .agentReview: "Added to every agent: how to write a review draft the app turns into buttons."
        case .agentReport: "Added to every agent: when and how to report to the workspace\u{2019}s Main with send_to_main."
        case .agentWhere: "Added to every agent: the paths of its workspace's MAIN.md, assistants, prompts, routines and usage log, so it never searches for them."
        case .mainReportNote: "Added to every Main: a report from another agent is information, never the user."
        case .unattendedRun: "Added to a routine or automation run: nobody is at the keyboard."
        case .automationRun: "Added to a run started by an event: it only drafts and never posts."
        case .automationAskRun: "Added when the automation asks the user next: end with a Recommendation line."
        }
    }

    /// Whether the app reads what the text asks for, so a change can stop the buttons from appearing.
    var warning: String? {
        switch self {
        case .reviewDraftFormat, .agentReview:
            "The app reads the worktime-review block this describes: keep its fields (pr, sha, verdict, summary, comments) and the fence."
        case .agentActions:
            "The app reads the worktime-action block this describes: keep its fields (title, assistant, prompt) and the fence."
        case .automationAskRun:
            "The app reads the line the run ends with: Recommendation: followed by one of the two button names."
        default: nil
        }
    }

    var placeholders: [PromptPlaceholder] {
        switch self {
        case .reviewPR:
            [PromptPlaceholder(name: "pr_url", note: "the pull request"),
             PromptPlaceholder(name: "pr_list_with_checkouts", note: "the pull request with its title and checkout, one line"),
             PromptPlaceholder(name: "draft_format", note: "the review draft format (the Review draft format template)")]
        case .reviewSet:
            Self.pullRequestSet + [PromptPlaceholder(name: "draft_format", note: "the review draft format (the Review draft format template)")]
        case .reviewSetSystem:
            Self.pullRequestSet + [PromptPlaceholder(name: "topic_name", note: "the agent\u{2019}s name"),
                                   PromptPlaceholder(name: "folder", note: "the folder the agent works in")]
        case .reviewPRAsk:
            Self.ask + Self.eventFields
        case .reviewSetAsk:
            Self.ask + Self.eventFields
        case .jiraAsk:
            Self.ask + Self.eventFields
        case .agentActions, .agentReview, .agentReport, .mainReportNote, .reviewDraftFormat:
            []
        case .agentWhere:
            AgentWhere.placeholders
        case .unattendedRun:
            [PromptPlaceholder(name: "kind", note: "automation or scheduled routine"), PromptPlaceholder(name: "name", note: "the routine\u{2019}s name")]
        case .automationRun:
            [PromptPlaceholder(name: "event", note: "what started the run, like \u{201C}a Slack message in #reviews\u{201D}")]
        case .automationAskRun:
            [PromptPlaceholder(name: "yes", note: "the first button\u{2019}s name"), PromptPlaceholder(name: "no", note: "the second button\u{2019}s name"),
             PromptPlaceholder(name: "yes_lower", note: "the first button\u{2019}s name in lower case"),
             PromptPlaceholder(name: "no_lower", note: "the second button\u{2019}s name in lower case")]
        }
    }

    private static let pullRequestSet = [
        PromptPlaceholder(name: "pr_count", note: "how many pull requests"),
        PromptPlaceholder(name: "pull_requests", note: "\u{201C}pull request\u{201D} or \u{201C}pull requests\u{201D}"),
        PromptPlaceholder(name: "these_pull_requests", note: "\u{201C}this pull request\u{201D} or \u{201C}these 3 pull requests\u{201D}"),
        PromptPlaceholder(name: "pr_urls", note: "their addresses, one bullet each"),
        PromptPlaceholder(name: "pr_list_with_checkouts", note: "each with its title and checkout, one line each"),
    ]

    private static let ask = [
        PromptPlaceholder(name: "draft_format", note: "the review draft format (the Review draft format template)"),
        PromptPlaceholder(name: "answer", note: "what the first look found"),
        PromptPlaceholder(name: "recommendation", note: "the reason the first look gave"),
    ]

    /// What the event of an automation fills in, whatever its kind: unused ones are left empty.
    private static let eventFields: [PromptPlaceholder] = {
        var seen = Set<String>(), found: [PromptPlaceholder] = []
        for field in AutomationTrigger.Kind.allCases.flatMap(\.fields) where seen.insert(field).inserted {
            found.append(PromptPlaceholder(name: field, note: "from the event"))
        }
        return found
    }()

    var placeholderNames: Set<String> { Set(placeholders.map(\.name)) }

    /// The text the template starts with.
    var builtIn: String {
        switch self {
        case .reviewPR: PromptBuiltIns.reviewPR
        case .reviewSet: PromptBuiltIns.reviewSet
        case .reviewSetSystem: PromptBuiltIns.reviewSetSystem
        case .reviewPRAsk: PromptBuiltIns.reviewPRAsk
        case .reviewSetAsk: PromptBuiltIns.reviewSetAsk
        case .jiraAsk: PromptBuiltIns.jiraAsk
        case .reviewDraftFormat: PromptBuiltIns.reviewDraftFormat
        case .agentActions: PromptBuiltIns.agentActions
        case .agentReview: PromptBuiltIns.agentReview
        case .agentReport: PromptBuiltIns.agentReport
        case .agentWhere: PromptBuiltIns.agentWhere
        case .mainReportNote: PromptBuiltIns.mainReportNote
        case .unattendedRun: PromptBuiltIns.unattendedRun
        case .automationRun: PromptBuiltIns.automationRun
        case .automationAskRun: PromptBuiltIns.automationAskRun
        }
    }
}

/// Reading a template file, filling in its placeholders and checking them.
enum PromptTemplates {
    /// The ``{name}`` placeholders a text holds, once each and in order. A brace that does not enclose a lower-case name is no placeholder, so a
    /// JSON example in a template is left alone.
    static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        scan(text) { name, _ in
            if !found.contains(name) { found.append(name) }
        }
        return found
    }

    /// The placeholders in `text` the template does not offer.
    static func unknown(in text: String, for template: PromptTemplate) -> [String] {
        let allowed = template.placeholderNames
        return placeholders(in: text).filter { !allowed.contains($0) }
    }

    /// `text` with the values in the place of their placeholders; one with no value is left as written. A value is never searched for
    /// placeholders again, so an answer that holds braces comes through as it is.
    static func render(_ text: String, _ values: [String: String]) -> String {
        var out = ""
        var cursor = text.startIndex
        scan(text) { name, range in
            guard let value = values[name] else { return }
            out += text[cursor..<range.lowerBound]
            out += value
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    private static func scan(_ text: String, _ visit: (String, Range<String.Index>) -> Void) {
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            let nameStart = text.index(after: open)
            guard let close = text[nameStart...].firstIndex(where: { !isNameCharacter($0) }), text[close] == "}", close > nameStart,
                  text[nameStart].isLetter else {
                index = nameStart
                continue
            }
            let end = text.index(after: close)
            visit(String(text[nameStart..<close]), open..<end)
            index = end
        }
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLowercase || character.isNumber) || character == "_"
    }

    // MARK: Pull request sets

    static func plural(_ count: Int) -> String { count == 1 ? "pull request" : "pull requests" }

    /// The values the pull request templates share: the count and its wording, and the pull requests as a list.
    static func pullRequestValues(urls: [String], lines: String) -> [String: String] {
        let count = urls.count
        return ["pr_count": String(count), "pull_requests": plural(count),
                "these_pull_requests": count == 1 ? "this pull request" : "these \(count) pull requests",
                "pr_urls": bullets(urls), "pr_list_with_checkouts": lines]
    }

    static func bullets(_ lines: [String]) -> String { lines.map { "- " + $0 }.joined(separator: "\n") }

    // MARK: Files

    /// The front matter of a template file: what it is for and what it can use. It is read back only for its version.
    static func file(_ template: PromptTemplate, body: String) -> String {
        var head = ["---", "description: \(template.summary)"]
        if !template.placeholders.isEmpty {
            head.append("placeholders: " + template.placeholders.map(\.name).joined(separator: ", "))
        }
        if let warning = template.warning { head.append("keep: \(warning)") }
        head += ["version: \(template.version)", "---", ""]
        return head.joined(separator: "\n") + "\n" + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// What a template file holds apart from its front matter, and the version written in it.
    static func parse(_ file: String) -> (body: String, version: Int?) {
        let text = file.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let head = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        let version = head.split(separator: "\n").compactMap { line -> Int? in
            line.hasPrefix("version:") ? Int(line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)) : nil
        }.first
        return (String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), version)
    }
}

extension PromptTemplates {
    private static let sampleURLs = ["https://github.com/acme-com/orbit.api/pull/12", "https://github.com/acme-com/orbit.admin/pull/7"]
    private static let sampleLines = [
        "- https://github.com/acme-com/orbit.api/pull/12 \u{2014} Retry the invoice export (checkout: ~/git/acme/orbit.api)",
        "- https://github.com/acme-com/orbit.admin/pull/7 \u{2014} Show the export status (checkout: ~/git/acme/orbit.admin)",
    ]

    /// Neutral values for every placeholder, so a template can be shown filled in without any real pull request or ticket.
    static func sampleValues(for template: PromptTemplate) -> [String: String] {
        let single = template == .reviewPR
        let urls = single ? Array(sampleURLs.prefix(1)) : sampleURLs
        var values = pullRequestValues(urls: urls, lines: sampleLines.prefix(urls.count).joined(separator: "\n"))
        values.merge([
            "pr_url": sampleURLs[0], "pr_title": "Retry the invoice export", "pr_repo": "acme-com/orbit.api", "pr_number": "12", "pr_author": "sam",
            "reviewer": "alex", "review_state": "changes requested", "ticket": "ACME-123", "ticket_title": "Retry the invoice export",
            "status": "In Progress", "from_status": "To Do", "url": "https://acme.atlassian.net/browse/ACME-123", "project": "ACME", "assignee": "Alex",
            "comment": "Looks good to me.", "comment_author": "alex", "slack_text": "Can someone review https://github.com/acme-com/orbit.api/pull/12?",
            "slack_place": "#reviews", "slack_author": "sam", "slack_link": "https://acme.slack.com/archives/C0123/p1",
            "answer": "The change is small and touches the invoice export.", "recommendation": "It touches money, so look at it first.",
            "topic_name": "Review: orbit.api #12 +1", "folder": "~/git/acme", "kind": "scheduled routine", "name": "Morning brief",
            "event": "a Slack message in #reviews", "yes": "Review it", "no": "Skip", "yes_lower": "review it", "no_lower": "skip",
        ]) { current, _ in current }
        values.merge(AgentWhere.sampleValues) { current, _ in current }
        return values
    }
}
