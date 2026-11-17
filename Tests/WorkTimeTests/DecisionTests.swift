import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z")!
private let source = NoticeSource(agent: "routine:7B2F6D9E-1C3A-4E5B-8F10-2A3B4C5D6E7F")

private func notice(_ id: String, urgency: NoticeUrgency = .normal, ask: NoticeAsk? = nil, state: AgentNotice.State = .shown,
                    created: Date = now, link: String? = nil) -> AgentNotice {
    var notice = AgentNotice(id: id, title: "Review? orbit.api#7", link: link, urgency: urgency, source: source, created: created, state: state)
    notice.ask = ask
    return notice
}

private func ask(event: String? = nil) -> NoticeAsk {
    NoticeAsk(routine: "R", yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: "p", reminder: "rem", event: event)
}

let decisionTests: [(name: String, run: () throws -> Void)] = [
    ("decisions: a question or a high-urgency result waits for an answer, a plain or scheduled one does not", {
        check(Decisions.needsAnswer(notice("a", ask: ask())), "a question")
        check(Decisions.needsAnswer(notice("b", urgency: .high)), "a high-urgency result")
        check(!Decisions.needsAnswer(notice("c")), "a plain notification")
        check(!Decisions.needsAnswer(notice("d", urgency: .high, state: .scheduled)), "not yet shown")
        let waiting = Decisions.waiting([notice("old", urgency: .high, created: now.addingTimeInterval(-60)), notice("plain"), notice("new", ask: ask())])
        check(waiting.map(\.id) == ["new", "old"], "newest first: \(waiting.map(\.id))")
    }),
    ("decisions: the bar drops down once for something new, only while the user is in none of the windows", {
        check(Decisions.shouldDrop(waiting: ["a"], dropped: [], enabled: true, appActive: false), "something new")
        check(!Decisions.shouldDrop(waiting: ["a"], dropped: ["a"], enabled: true, appActive: false), "not again for the same")
        check(Decisions.shouldDrop(waiting: ["a", "b"], dropped: ["a"], enabled: true, appActive: false), "a second one is new")
        check(!Decisions.shouldDrop(waiting: ["a"], dropped: [], enabled: true, appActive: true), "the user is in a window")
        check(!Decisions.shouldDrop(waiting: ["a"], dropped: [], enabled: false, appActive: false), "setting off")
        check(!Decisions.shouldDrop(waiting: [], dropped: [], enabled: true, appActive: false), "nothing waits")
        let defaults = UserDefaults(suiteName: "decisions-\(UUID().uuidString)")!
        check(Decisions.dropsDown(defaults: defaults) && Decisions.keepOnScreen(defaults: defaults), "both on by default")
        defaults.set(false, forKey: Decisions.dropDownKey)
        check(!Decisions.dropsDown(defaults: defaults), "off when switched off")
    }),
    ("decisions: a notification that was swept away comes back after 10 and 30 minutes and an hour, then no more", {
        func due(_ minutes: Double, _ reposts: Int) -> Bool { Decisions.repostDue(first: now, reposts: reposts, now: now.addingTimeInterval(minutes * 60)) }
        check(!due(9, 0) && due(10, 0), "first after ten minutes")
        check(!due(29, 1) && due(30, 1), "second after thirty")
        check(!due(59, 2) && due(60, 2), "third after an hour")
        check(!due(600, 3), "then it is left to the notch bar")
    }),
    ("decisions: the style warning says when a decision cannot stay on screen", {
        check(Decisions.styleWarning(.alert, authorized: true) == nil, "alerts stay")
        check(Decisions.styleWarning(.banner, authorized: true)?.contains("Alerts") == true, "banners leave")
        check(Decisions.styleWarning(.none, authorized: true) != nil, "none shown")
        check(Decisions.styleWarning(.alert, authorized: false)?.contains("off") == true, "not allowed at all")
    }),
    ("decisions: a question about an event already asked about is updated, not asked twice", {
        let first = notice("first", ask: ask(event: "slack_channel:C1.1"))
        let again = notice("second", ask: ask(event: "slack_channel:C1.1"))
        check(NoticeLogic.admit(again, existing: [first], recent: [first], now: now) == .replace("first"), "the same event")
        let other = notice("third", ask: ask(event: "slack_channel:C1.2"))
        check(NoticeLogic.admit(other, existing: [first], recent: [], now: now) == .add, "another event")
        check(NoticeLogic.admit(notice("fourth", ask: ask()), existing: [first], recent: [], now: now) == .add, "no event, nothing to match")
    }),
    ("slack: markup becomes plain words, lines are kept, and what only looks like markup stays", {
        let text = "Review <https://github.com/acme-com/orbit.api/pull/7|orbit.api #7> <@U0BO> in <#C0DEV|dev> &amp; <!here>\nthanks"
        check(SlackLogic.plain(text, names: ["U0BO": "Bo"]) == "Review orbit.api #7 @Bo in #dev & @here\nthanks", SlackLogic.plain(text, names: ["U0BO": "Bo"]))
        check(SlackLogic.plain("<https://x.com/a> <mailto:a@b.se|a@b.se>") == "https://x.com/a a@b.se", "bare links")
        check(SlackLogic.plain("if a < b and c > d") == "if a < b and c > d", "a comparison is not markup")
        check(SlackLogic.plain("Decide: <https://github.com/acme-com/orbit.api/pull/7|g") == "Decide: g", "a link cut off by a clipped title")
        check(SlackLogic.plain("see <https://x.com/a") == "see https://x.com/a", "a bare link cut off")
        check(SlackLogic.clean("a\nb", names: [:]) == "a b", "clean still makes one line")
    }),
    ("slack: an event about a message names the pull request but reads as plain text", {
        let message = SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: "review-request", author: "Kim",
                                   text: "Please look at <https://github.com/acme-com/orbit.api/pull/7|github.com/acme-com/orbit.api/pull/7> <@U0BO>",
                                   ts: "1763380000.000100", permalink: nil, unread: nil, threadTS: nil)
        let event = Automations.slackEvent(message, link: nil)
        check(event.pullRequest == "https://github.com/acme-com/orbit.api/pull/7", "the pull request: \(String(describing: event.pullRequest))")
        check(!event.text.contains("<") && !event.title.contains("<") && !(event.fields["slack_text"] ?? "").contains("<"), "no markup: \(event.text)")
        check(event.text.hasPrefix("Please look at github.com/acme-com/orbit.api/pull/7"), event.text)
    }),
    ("decisions: a dismissed decision leaves a source its reminder can point to", {
        check(Decisions.resolvedSource(link: "https://github.com/acme-com/orbit.api/pull/7") == .pullRequest(GitHubLink.pullRequest(at: "https://github.com/acme-com/orbit.api/pull/7")!), "a pull request")
        check(Decisions.resolvedSource(link: "ACME-12")?.kind == .jira, "a Jira key")
        check(Decisions.resolvedSource(link: "assistant:work:reviewer") == nil, "an agent is nothing to point to")
        check(Decisions.resolvedSource(link: nil) == nil, "no link")
    }),
]
