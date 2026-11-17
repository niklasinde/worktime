import Foundation

/// What starts an automation: an event the app already follows, narrowed by what its place and its text contain.
struct AutomationTrigger: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case slackMessage = "slack_message"
        case reviewRequested = "review_requested"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .slackMessage: "A Slack message"
            case .reviewRequested: "A review is requested from me"
            }
        }

        var placeTitle: String { self == .slackMessage ? "Channel or person" : "Repository" }
        var textTitle: String { self == .slackMessage ? "Message contains" : "Title contains" }

        /// The placeholders a prompt can use for this kind of event.
        var fields: [String] {
            switch self {
            case .slackMessage: ["slack_text", "slack_place", "slack_author", "slack_link", "pr_url", "ticket"]
            case .reviewRequested: ["pr_url", "pr_title", "pr_repo", "pr_number", "pr_author", "ticket"]
            }
        }

        var defaultPrompt: String {
            switch self {
            case .slackMessage:
                "A message in {slack_place} from {slack_author}: {slack_text}\n{slack_link}\n\n"
                    + "If it asks for a review of a pull request, review {pr_url}: read the diff and the code around it and draft a review. "
                    + "Otherwise say in two lines what it asks and what I should do."
            case .reviewRequested:
                "Review {pr_url} ({pr_title}, by {pr_author}). Read the diff and the code around it, then draft the review: "
                    + "a verdict (approve, request changes or needs the author's input), the problems that block it and the small ones."
            }
        }
    }

    var kind: Kind
    /// Slack: the channel or the person; GitHub: the repository. Any of several, separated by commas.
    var place = ""
    /// The message text or the pull request title. Any of several, separated by commas.
    var text = ""
    /// Slack only: the message has to mention a pull request.
    var needsPullRequest = false
}

/// What happens after an automation's run: a notification, and a reminder about the thing it ran for.
struct AutomationFollowUp: Codable, Equatable, Sendable {
    var notify = true
    var remind = false
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
    var link: String?
    var date: Date
}

/// What the app remembers between runs: the events each automation has seen, so a restart fires none twice, which ones were
/// already there when it was turned on, when it last ran, and the latest event it matched (for testing it).
struct AutomationState: Codable, Equatable, Sendable {
    var seen: [String: [String]] = [:]
    var baselined: Set<String> = []
    var fired: [String: [Date]] = [:]
    var last: [String: AutomationEvent] = [:]

    mutating func rebaseline(_ id: String) {
        baselined.remove(id)
        seen[id] = nil
    }

    func pruned(keeping routines: [Routine]) -> AutomationState {
        let ids = Set(routines.map(\.id))
        var copy = self
        copy.seen = seen.filter { ids.contains($0.key) }
        copy.baselined = baselined.intersection(ids)
        copy.fired = fired.filter { ids.contains($0.key) }
        copy.last = last.filter { ids.contains($0.key) }
        return copy
    }
}

enum Automations {
    static let seenLimit = 500
    static let runsPerHour = 6
    static let queueLimit = 20
    static let titleLimit = 90

    // MARK: Triggers

    static func problem(_ trigger: AutomationTrigger) -> String? {
        if trigger.kind == .slackMessage, words(trigger.place).isEmpty, words(trigger.text).isEmpty, !trigger.needsPullRequest {
            return "Say which Slack messages: a channel or person, some text in the message, or that it mentions a pull request. Otherwise every mention and direct message starts a run."
        }
        return nil
    }

    static func matches(_ trigger: AutomationTrigger, _ event: AutomationEvent) -> Bool {
        guard trigger.kind == event.kind else { return false }
        func contains(_ filter: String, _ text: String) -> Bool {
            let options = words(filter)
            return options.isEmpty || options.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        if trigger.needsPullRequest, event.pullRequest == nil { return false }
        return contains(trigger.place, event.place) && contains(trigger.text, event.text)
    }

    private static func words(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func label(_ trigger: AutomationTrigger) -> String {
        var text = trigger.kind == .slackMessage ? "Slack message" : "Review requested"
        if !words(trigger.place).isEmpty { text += " in " + words(trigger.place).joined(separator: " or ") }
        if !words(trigger.text).isEmpty { text += " with \u{201C}\(words(trigger.text).joined(separator: "\u{201D} or \u{201C}"))\u{201D}" }
        if trigger.needsPullRequest { text += " linking a pull request" }
        return text
    }

    // MARK: Events

    static func slackEvent(_ message: SlackMessage, link: URL?) -> AutomationEvent {
        let mentioned = GitHubLink.mentions(in: message.text).first
        var fields = ["slack_text": message.text, "slack_place": message.place, "slack_author": message.author ?? message.place,
                      "slack_link": link?.absoluteString ?? ""]
        if let mentioned { fields["pr_url"] = mentioned.url }
        if let ticket = ActivityLogic.ticket(in: message.text) { fields["ticket"] = ticket }
        return AutomationEvent(id: "slack:" + message.id, kind: .slackMessage, title: String(message.text.prefix(titleLimit)), place: message.place,
                               text: message.text, fields: fields, pullRequest: mentioned?.url, link: link?.absoluteString, date: message.date)
    }

    static func pullRequestEvent(_ pr: GitHubPR) -> AutomationEvent {
        var fields = ["pr_url": pr.url, "pr_title": pr.title, "pr_repo": pr.repo, "pr_number": String(pr.number), "pr_author": pr.author ?? "someone"]
        if let ticket = pr.ticket ?? ActivityLogic.ticket(in: pr.title) { fields["ticket"] = ticket }
        return AutomationEvent(id: "review:" + pr.url, kind: .reviewRequested, title: "\(GitHubLogic.repoName(pr.repo).name) #\(pr.number) \(pr.title)",
                               place: pr.repo, text: pr.title, fields: fields, pullRequest: pr.url, link: pr.url, date: pr.updated)
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
        if let url = event.pullRequest, let target = GitHubLink.pullRequest(at: url) {
            return ("Decide on \(GitHubLogic.repoName(target.repo).name) #\(target.number): \(event.text)", .pullRequest(target))
        }
        guard let link = event.link.flatMap(URL.init(string:)) else { return nil }
        return ("Answer \(event.place): \(event.text)", .slack(link: link, place: event.place))
    }

    static func systemNote(_ routine: Routine) -> String {
        "This run was started by an event (\(routine.trigger.map(label) ?? "an event")). Nothing you write is posted or sent: your answer is a draft shown to the user. "
            + "Never approve, merge, close or comment on a pull request, or send a message; the user decides."
    }
}
