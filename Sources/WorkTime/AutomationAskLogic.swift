import Foundation

/// What an automation asks the user once its run is done: a notification with two buttons, and what the first one starts.
struct AutomationAsk: Codable, Equatable, Sendable {
    static let labelLimit = 24

    var yes = "Review it"
    var no = "Skip"
    /// The assistant to start, by key; empty starts the agent of the pull request the event is about.
    var agent = ""
    /// What is sent to it: the event's fields, `{recommendation}` and `{answer}` filled in. Empty for the default of the event.
    var prompt = ""

    /// The buttons of an event's question: a pull request is reviewed, a ticket started.
    static func defaults(for kind: AutomationTrigger.Kind) -> AutomationAsk {
        AutomationAsk(yes: kind.source == .jira ? "Start it" : "Review it", no: "Skip")
    }
}

/// An unanswered question, kept with the notification that asks it so it survives a restart.
struct NoticeAsk: Codable, Equatable, Sendable {
    var routine: String
    var yes: String
    var no: String
    /// An assistant key or a pull request url.
    var agent: String
    /// The text the first button sends.
    var prompt: String
    /// The reminder that stays until the question is answered.
    var reminder: String?
    /// The pull requests the first button hands to one agent that works on them together, when the event names several.
    var pullRequests: [String]?
    /// The event it asks about, so the same event never asks twice.
    var event: String?
    /// What the event said, for the row to show when it is opened.
    var eventText: String?
    /// For an assistant: the ticket, else the pull request, whose session of it gets the prompt.
    var ticket: String?
    var pullRequest: String?
    /// What the event was, like `Review requested in #review-request`, shown in the session's timeline.
    var origin: String?
    var links: [LinkEntity]?
}

/// The user's last answer to an automation's question, for its row.
struct AskAnswer: Codable, Equatable, Sendable {
    var title: String
    var yes: Bool
    var date: Date
}

enum AutomationAsks {
    static let yesAction = "ask-yes"
    static let noAction = "ask-no"
    static let openAction = "ask-open"
    static let categoryPrefix = "automation-ask:"
    static let answerLimit = 3000

    static func category(yes: String, no: String) -> String { "\(categoryPrefix)\(yes)|\(no)" }

    static func category(_ ask: NoticeAsk) -> String { category(yes: ask.yes, no: ask.no) }

    // MARK: Recommendation

    /// The triage run's own advice, from the line it ends with: `Recommendation: review - the change is small`.
    struct Recommendation: Equatable {
        enum Verdict: Equatable { case yes, skip }
        var verdict: Verdict?
        var reason: String
    }

    private static let yesWords: Set<String> = ["yes", "review", "start", "go", "proceed", "do"]
    private static let skipWords: Set<String> = ["skip", "no", "ignore", "dismiss", "pass", "later"]
    private static let marker = "recommendation:"

    private static func recommendationLine(in answer: String) -> (index: Int, text: String)? {
        let lines = answer.components(separatedBy: .newlines)
        for index in lines.indices.reversed() {
            let line = lines[index].trimmingCharacters(in: CharacterSet(charactersIn: "*_#>-\u{2022} \t"))
            guard line.lowercased().hasPrefix(marker) else { continue }
            return (index, String(line.dropFirst(marker.count)))
        }
        return nil
    }

    /// `yes` and `no` are the button names: their first word counts as a verdict too.
    static func recommendation(in answer: String?, yes: String = "", no: String = "") -> Recommendation? {
        guard let answer, let found = recommendationLine(in: answer) else { return nil }
        func word(_ text: String) -> String { text.lowercased().split { !$0.isLetter }.first.map(String.init) ?? "" }
        let yesWord = word(yes), noWord = word(no)
        let separators = CharacterSet(charactersIn: "*_ \t-\u{2013}\u{2014}:,.;")
        let rest = found.text.trimmingCharacters(in: separators)
        guard !rest.isEmpty else { return nil }
        let first = rest.prefix { $0.isLetter }.lowercased()
        let reason = String(rest.dropFirst(first.count)).trimmingCharacters(in: separators)
        if yesWords.contains(first) || first == yesWord { return Recommendation(verdict: .yes, reason: reason) }
        if skipWords.contains(first) || first == noWord { return Recommendation(verdict: .skip, reason: reason) }
        return Recommendation(verdict: nil, reason: rest)
    }

    /// The answer without its recommendation line.
    static func answer(_ answer: String?) -> String {
        guard let answer else { return "" }
        var lines = answer.components(separatedBy: .newlines)
        if let found = recommendationLine(in: answer) { lines.remove(at: found.index) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Notification

    /// The notification of a finished run that asks: the event as the title, the recommendation and the first lines of the answer as the body.
    static func notification(for routine: Routine, event: AutomationEvent, run: RoutineRun, ask: AutomationAsk) -> (title: String, body: String) {
        var lines: [String] = []
        if let advice = recommendation(in: run.summary, yes: ask.yes, no: ask.no), let verdict = advice.verdict {
            let label = verdict == .yes ? ask.yes : ask.no
            lines.append("Recommended: \(label)" + (advice.reason.isEmpty ? "" : " \u{2014} \(advice.reason)"))
        }
        let rest = answer(run.summary).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lines += rest.prefix(Routines.notificationLines - lines.count)
        var body = lines.joined(separator: "\n")
        if body.count > Routines.notificationLimit { body = String(body.prefix(Routines.notificationLimit - 1)) + "\u{2026}" }
        if body.isEmpty { body = "Waiting for your answer." }
        return ("\(routine.name): \(event.title)", body)
    }

    /// The question to keep with the notification, or nil when there is nobody to start: no assistant named and the event has no pull request.
    static func notice(for routine: Routine, event: AutomationEvent, run: RoutineRun, ask: AutomationAsk, reminder: String?) -> NoticeAsk? {
        guard let agent = ask.agent.isEmpty ? event.pullRequest : ask.agent else { return nil }
        let advice = recommendation(in: run.summary, yes: ask.yes, no: ask.no)
        let several = ask.agent.isEmpty ? event.pullRequests : nil
        var text = ask.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = several == nil ? defaultPrompt(for: event.kind, workspace: routine.workspace) : setPrompt(workspace: routine.workspace)
        } else {
            text = PromptTemplates.render(text, ["draft_format": PromptTemplates.body(.reviewDraftFormat, workspace: routine.workspace)])
        }
        text = Automations.prompt(text, event: event)
        text = text.replacingOccurrences(of: "{recommendation}", with: advice?.reason ?? "")
        text = text.replacingOccurrences(of: "{answer}", with: String(answer(run.summary).prefix(answerLimit)))
        let forAssistant = Assistants.isKey(agent)
        let ticket = forAssistant ? event.fields["ticket"].flatMap(JiraLogic.issueKey) : nil
        let links = [event.link.flatMap(LinkTargets.entity), event.fields["ticket"].flatMap(LinkTargets.jira), event.pullRequest.flatMap(LinkTargets.pullRequest)].compactMap { $0 }
            + (event.pullRequests ?? []).compactMap(LinkTargets.pullRequest)
        return NoticeAsk(routine: routine.id, yes: ask.yes, no: ask.no, agent: agent, prompt: String(text.prefix(AgentInbox.textLimit)), reminder: reminder,
                         pullRequests: several, event: event.id, eventText: [event.title, event.text].filter { !$0.isEmpty }.joined(separator: "\n"),
                         ticket: ticket, pullRequest: forAssistant && ticket == nil ? event.pullRequest : nil, origin: origin(of: event), links: Array(Set(links)).sorted())
    }

    /// What started the run: the kind of event and where it happened.
    static func origin(of event: AutomationEvent) -> String {
        event.kind.shortTitle + (event.place.isEmpty ? "" : " in " + event.place)
    }

    /// What the first button sends to the one agent for several pull requests, with `{pr_urls}` and `{answer}` still to fill in.
    static func setPrompt(workspace: String? = nil, files: PromptFiles = .current) -> String {
        PromptTemplates.render(.reviewSetAsk, workspace: workspace, files: files)
    }

    static var defaultSetPrompt: String { setPrompt() }

    /// What the first button sends when the automation names nothing: a pull request is reviewed, a ticket started.
    static func defaultPrompt(for kind: AutomationTrigger.Kind, workspace: String? = nil, files: PromptFiles = .current) -> String {
        PromptTemplates.render(kind.source == .jira ? .jiraAsk : .reviewPRAsk, workspace: workspace, files: files)
    }

    /// Why the question cannot be saved, nil when it can.
    static func problem(_ ask: AutomationAsk, trigger: AutomationTrigger, assistants: Set<String>) -> String? {
        let yes = ask.yes.trimmingCharacters(in: .whitespacesAndNewlines), no = ask.no.trimmingCharacters(in: .whitespacesAndNewlines)
        if yes.isEmpty || no.isEmpty { return "Give both buttons a name." }
        if yes.count > AutomationAsk.labelLimit || no.count > AutomationAsk.labelLimit { return "A button name is at most \(AutomationAsk.labelLimit) characters." }
        if yes.caseInsensitiveCompare(no) == .orderedSame { return "The two buttons need different names." }
        if ask.agent.isEmpty {
            if trigger.kind.source == .jira { return "Choose the assistant the first button starts: a ticket has no pull request agent." }
        } else if !assistants.contains(ask.agent), GitHubLink.pullRequest(at: ask.agent) == nil {
            return "No assistant with key \(ask.agent)." + (assistants.isEmpty ? "" : " Known: \(assistants.sorted().joined(separator: ", "))")
        }
        return nil
    }

    /// The question as saved: the button names trimmed.
    static func trimmed(_ ask: AutomationAsk) -> AutomationAsk {
        var ask = ask
        ask.yes = ask.yes.trimmingCharacters(in: .whitespacesAndNewlines)
        ask.no = ask.no.trimmingCharacters(in: .whitespacesAndNewlines)
        ask.prompt = ask.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return ask
    }

    /// The row's note about the last answer, like "started 5 min ago".
    static func answered(_ answer: AskAnswer?, now: Date) -> String? {
        answer.map { "\($0.yes ? "started" : "skipped") \(GitHubLogic.updatedText($0.date, now: now))" }
    }

    /// The row's second line when questions wait for the user.
    static func waiting(_ count: Int) -> String? { count > 0 ? "\(count) waiting for you" : nil }
}
