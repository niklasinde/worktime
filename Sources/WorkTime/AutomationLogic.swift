import Foundation

/// What starts an automation: an event the app follows, narrowed by what its place and its text contain.
struct AutomationTrigger: Codable, Equatable, Sendable {
    var kind: Kind
    /// The channel or person, the repository or the Jira project. Any of several, separated by commas.
    var place = ""
    /// The message text, the pull request title, the ticket summary or the comment. Any of several, separated by commas.
    var text = ""
    /// Slack only: the message has to mention a pull request.
    var needsPullRequest = false
    /// Jira status changes: the status it moves to and the one it moves from. Any of several, separated by commas.
    var status = ""
    var fromStatus = ""
    /// Jira: a query the ticket has to match too.
    var jql = ""
    /// A regular expression the text has to match.
    var pattern = ""

    func value(_ input: Input) -> String {
        switch input {
        case .place: place
        case .text: text
        case .status: status
        case .fromStatus: fromStatus
        case .jql: jql
        case .pattern: pattern
        }
    }

    mutating func set(_ input: Input, _ value: String) {
        switch input {
        case .place: place = value
        case .text: text = value
        case .status: status = value
        case .fromStatus: fromStatus = value
        case .jql: jql = value
        case .pattern: pattern = value
        }
    }
}

extension AutomationTrigger {
    /// Reads the triggers saved before they could be narrowed further.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        place = try container.decodeIfPresent(String.self, forKey: .place) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        needsPullRequest = try container.decodeIfPresent(Bool.self, forKey: .needsPullRequest) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        fromStatus = try container.decodeIfPresent(String.self, forKey: .fromStatus) ?? ""
        jql = try container.decodeIfPresent(String.self, forKey: .jql) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
    }
}

/// What happens after an automation's run: a notification, and a reminder about the thing it ran for.
struct AutomationFollowUp: Codable, Equatable, Sendable {
    var notify = true
    var remind = false
    /// Ask the user before the next step: the notification carries two buttons, and the first starts an agent.
    var ask: AutomationAsk?
}

/// One thing that happened, as the triggers see it.
struct AutomationEvent: Codable, Equatable, Sendable {
    var id: String
    var kind: AutomationTrigger.Kind
    var title: String
    var place: String
    var text: String
    var fields: [String: String]
    /// The pull request the event is about or mentions.
    var pullRequest: String?
    /// Every pull request the event mentions when there are several, for an agent that works on them together.
    var pullRequests: [String]?
    var link: String?
    var date: Date
}

/// What the app remembers between runs: the events each automation has seen, so a restart fires none twice, which ones were
/// already there when it was turned on, when it last ran, the latest event it matched (for testing it) and the ones queued.
struct AutomationState: Codable, Equatable, Sendable {
    var seen: [String: [String]] = [:]
    var baselined: Set<String> = []
    var fired: [String: [Date]] = [:]
    var last: [String: AutomationEvent] = [:]
    /// The events waiting for the run an automation is in the middle of, kept so a restart does not lose them.
    var queued: [String: [AutomationEvent]] = [:]
    /// The user's last answer to each automation's question.
    var answers: [String: AskAnswer] = [:]

    mutating func rebaseline(_ id: String) {
        baselined.remove(id)
        seen[id] = nil
        queued[id] = nil
    }

    mutating func rebaselineAll() {
        baselined = []
        seen = [:]
        queued = [:]
    }

    func pruned(keeping routines: [Routine]) -> AutomationState {
        let ids = Set(routines.map(\.id))
        var copy = self
        copy.seen = seen.filter { ids.contains($0.key) }
        copy.baselined = baselined.intersection(ids)
        copy.fired = fired.filter { ids.contains($0.key) }
        copy.last = last.filter { ids.contains($0.key) }
        copy.queued = queued.filter { ids.contains($0.key) }
        copy.answers = answers.filter { ids.contains($0.key) }
        return copy
    }
}

extension AutomationState {
    /// Reads the state saved before events could be queued.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = try container.decode([String: [String]].self, forKey: .seen)
        baselined = try container.decode(Set<String>.self, forKey: .baselined)
        fired = try container.decode([String: [Date]].self, forKey: .fired)
        last = try container.decode([String: AutomationEvent].self, forKey: .last)
        queued = try container.decodeIfPresent([String: [AutomationEvent]].self, forKey: .queued) ?? [:]
        answers = try container.decodeIfPresent([String: AskAnswer].self, forKey: .answers) ?? [:]
    }
}

enum Automations {
    static let seenLimit = 500
    static let runsPerHour = 6
    static let queueLimit = 20
    static let titleLimit = 90
    /// A status change, a comment or a reply older than this is not an event: the app was off, or it is history.
    static let recentWindow: TimeInterval = 2 * 86_400
    static let enabledKey = "automationsEnabled"

    /// The switch for all automations, on until turned off in Settings.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    // MARK: Triggers

    static func problem(_ trigger: AutomationTrigger) -> String? {
        let kind = trigger.kind
        if kind == .slackMessage, words(trigger.place).isEmpty, words(trigger.text).isEmpty, !trigger.needsPullRequest {
            return "Say which Slack messages: a channel or person, some text in the message, or that it mentions a pull request. Otherwise every mention and direct message starts a run."
        }
        if let input = kind.required, words(trigger.value(input)).isEmpty {
            return "Say \(kind.title(of: input).lowercased()): \(kind.title.lowercased()) needs it."
        }
        if kind == .jiraNew, words(trigger.place).isEmpty, trigger.jql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Say which project or JQL: otherwise every new ticket in Jira starts a run."
        }
        if !trigger.pattern.isEmpty, regex(trigger.pattern) == nil { return "The regex is not valid." }
        if kind.source != .slack, trigger.needsPullRequest { return "Only Slack triggers can need a pull request." }
        return nil
    }

    static func matches(_ trigger: AutomationTrigger, _ event: AutomationEvent) -> Bool {
        guard trigger.kind == event.kind else { return false }
        if trigger.needsPullRequest, event.pullRequest == nil { return false }
        if !trigger.pattern.isEmpty {
            guard let regex = regex(trigger.pattern), regex.firstMatch(in: event.text, range: NSRange(event.text.startIndex..., in: event.text)) != nil else { return false }
        }
        return contains(trigger.place, event.place) && contains(trigger.text, event.text)
            && contains(trigger.status, event.fields["status"] ?? "") && contains(trigger.fromStatus, event.fields["from_status"] ?? "")
    }

    /// The text has one of the comma-separated options, ignoring case and accents; any text has none asked for.
    static func contains(_ filter: String, _ text: String) -> Bool {
        let options = words(filter)
        return options.isEmpty || options.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func words(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func label(_ trigger: AutomationTrigger) -> String {
        var text = trigger.kind.shortTitle
        func options(_ input: AutomationTrigger.Input) -> String { words(trigger.value(input)).joined(separator: " or ") }
        if !options(.place).isEmpty { text += " in " + options(.place) }
        if !options(.fromStatus).isEmpty { text += " from " + options(.fromStatus) }
        if !options(.status).isEmpty { text += " to " + options(.status) }
        if !options(.text).isEmpty { text += " with \u{201C}\(words(trigger.text).joined(separator: "\u{201D} or \u{201C}"))\u{201D}" }
        if !trigger.pattern.isEmpty { text += " matching /\(trigger.pattern)/" }
        if !trigger.jql.isEmpty { text += " matching a JQL query" }
        if trigger.needsPullRequest { text += " linking a pull request" }
        return text
    }

    // MARK: Events

    static func slackEvent(_ message: SlackMessage, link: URL?, kind: AutomationTrigger.Kind = .slackMessage) -> AutomationEvent {
        let mentions = GitHubLink.mentions(in: message.text)
        let mentioned = mentions.first
        let text = SlackLogic.plain(message.text)
        let line = text.replacingOccurrences(of: "\n", with: " ")
        var fields = ["slack_text": text, "slack_place": message.place, "slack_author": message.author ?? message.place,
                      "slack_link": link?.absoluteString ?? ""]
        if let mentioned { fields["pr_url"] = mentioned.url }
        let several = PullRequestSets.urls(in: message.text)
        if let several { fields["pr_urls"] = several.joined(separator: "\n") }
        if let ticket = ActivityLogic.ticket(in: message.text) { fields["ticket"] = ticket }
        return AutomationEvent(id: "\(kind.idPrefix):" + message.id, kind: kind, title: String(line.prefix(titleLimit)), place: message.place,
                               text: line, fields: fields, pullRequest: mentioned?.url, pullRequests: several, link: link?.absoluteString, date: message.date)
    }

    /// A pull request as an event. `suffix` tells apart the events one pull request makes, such as each review or each push.
    static func pullRequestEvent(_ pr: GitHubPR, kind: AutomationTrigger.Kind = .reviewRequested, suffix: String? = nil,
                                 extra: [String: String] = [:], date: Date? = nil) -> AutomationEvent {
        var fields = ["pr_url": pr.url, "pr_title": pr.title, "pr_repo": pr.repo, "pr_number": String(pr.number), "pr_author": pr.author ?? "someone"]
        if let ticket = pr.ticket ?? ActivityLogic.ticket(in: pr.title) { fields["ticket"] = ticket }
        fields.merge(extra) { $1 }
        return AutomationEvent(id: "\(kind.idPrefix):" + pr.url + (suffix.map { ":" + $0 } ?? ""), kind: kind,
                               title: "\(GitHubLogic.repoName(pr.repo).name) #\(pr.number) \(pr.title)", place: pr.repo, text: pr.title, fields: fields,
                               pullRequest: pr.url, link: pr.url, date: date ?? pr.updated)
    }

    /// The prompt with the event's fields in the place of its placeholders; one that is not there is left empty.
    static func prompt(_ template: String, event: AutomationEvent) -> String {
        var text = template
        for field in event.kind.fields { text = text.replacingOccurrences(of: "{\(field)}", with: event.fields[field] ?? "") }
        return text
    }

    // MARK: Firing

    struct Firing: Equatable {
        let routine: String
        let event: AutomationEvent
    }

    /// Which automations fire for the events of one kind, and the state after. Call it only once the source has loaded: the first
    /// time an automation sees the events, the ones already there are marked seen and start nothing. An event fires once, and an
    /// automation runs at most `runsPerHour` times an hour; what is over that is skipped.
    static func plan(kind: AutomationTrigger.Kind, events: [AutomationEvent], routines: [Routine], state: AutomationState,
                     now: Date) -> (fire: [Firing], state: AutomationState) {
        var state = state, fire: [Firing] = []
        for routine in routines where routine.enabled {
            guard let trigger = routine.trigger, trigger.kind == kind else { continue }
            let matching = events.filter { matches(trigger, $0) }.sorted { $0.date < $1.date }
            if let latest = matching.last { state.last[routine.id] = latest }
            guard state.baselined.contains(routine.id) else {
                state.baselined.insert(routine.id)
                state.seen[routine.id] = Array(matching.map(\.id).suffix(seenLimit))
                continue
            }
            var seen = state.seen[routine.id] ?? []
            var recent = (state.fired[routine.id] ?? []).filter { now.timeIntervalSince($0) < 3600 }
            for event in matching where !seen.contains(event.id) {
                seen.append(event.id)
                guard recent.count < runsPerHour else { continue }
                recent.append(now)
                fire.append(Firing(routine: routine.id, event: event))
            }
            state.seen[routine.id] = Array(seen.suffix(seenLimit))
            state.fired[routine.id] = recent
        }
        return (fire, state)
    }

    // MARK: Follow-up

    /// What the notification of a run for an event says: the event as the title, the first lines of the answer as the body.
    static func notification(for routine: Routine, event: AutomationEvent, run: RoutineRun) -> (title: String, body: String) {
        let text = Routines.notification(for: routine, run: run)
        return ("\(routine.name): \(event.title)", text.body)
    }

    /// The reminder to make for an event, with where it came from; nil when the event names nothing to come back to.
    static func reminder(for event: AutomationEvent) -> (title: String, source: ReminderSource)? {
        let ticket = event.fields["ticket"] ?? ""
        switch event.kind.source {
        case .jira:
            guard !ticket.isEmpty else { return nil }
            let verb: String
            switch event.kind {
            case .jiraAssigned: verb = "Start"
            case .jiraStatus: verb = "Check"
            case .jiraNew: verb = "Triage"
            default: verb = "Answer the comment on"
            }
            return ("\(verb) \(ticket): \(event.fields["ticket_title"] ?? event.title)", .jira(key: ticket, summary: event.fields["ticket_title"]))
        case .github:
            guard let url = event.pullRequest, let target = GitHubLink.pullRequest(at: url) else { return nil }
            let name = "\(GitHubLogic.repoName(target.repo).name) #\(target.number)"
            let verb: String
            switch event.kind {
            case .ciFailed: verb = "Fix the checks on"
            case .prFeedback: verb = "Answer the review on"
            case .prApproved: verb = "Merge"
            case .prMerged: verb = "Follow up on"
            case .prMentioned: verb = "Answer the mention on"
            default: verb = "Decide on"
            }
            return ("\(verb) \(name): \(event.text)", .pullRequest(target))
        default:
            if let url = event.pullRequest, let target = GitHubLink.pullRequest(at: url) {
                return ("Decide on \(GitHubLogic.repoName(target.repo).name) #\(target.number): \(event.text)", .pullRequest(target))
            }
            guard let link = event.link.flatMap(URL.init(string:)) else { return nil }
            return ("Answer \(event.place): \(event.text)", .slack(link: link, place: event.place))
        }
    }

    /// Where a notification about the event leads: the pull request or the ticket, else the automation's own agent (nil).
    static func noticeLink(for event: AutomationEvent) -> String? {
        event.pullRequest ?? (event.kind.source == .jira ? event.link : nil)
    }

    static func systemNote(_ routine: Routine) -> String {
        var note = "This run was started by an event (\(routine.trigger.map(label) ?? "an event")). Nothing you write is posted or sent: your answer is a draft shown to the user. "
            + "Never approve, merge, close or comment on a pull request, or comment on, move or assign a ticket, or send a message; the user decides."
        if let ask = routine.followUp?.ask {
            note += " The user is asked next, with the buttons \u{201C}\(ask.yes)\u{201D} and \u{201C}\(ask.no)\u{201D} on a notification: do not tell them to open anything or to answer in a chat. "
                + "Give your findings in a few short lines, then end with one line: Recommendation: \(ask.yes.lowercased()) or Recommendation: \(ask.no.lowercased()), "
                + "a dash and the reason in one sentence."
        }
        return note
    }
}
