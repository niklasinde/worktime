import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let pull = "https://github.com/acme-com/orbit.api/pull/12"

private func review(_ ask: AutomationAsk? = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer")) -> Routine {
    Routine(id: "A1", name: "Reviews", prompt: "triage", workspace: "work", schedule: RoutineSchedule(kind: .daily), created: now,
            trigger: AutomationTrigger(kind: .reviewRequested), followUp: AutomationFollowUp(notify: true, remind: true, ask: ask))
}

private func event(pullRequest: String? = pull) -> AutomationEvent {
    AutomationEvent(id: "review:1", kind: .reviewRequested, title: "orbit.api #12 Change", place: "acme-com/orbit.api", text: "Change",
                    fields: ["pr_url": pull, "pr_title": "Change", "pr_author": "Katia"], pullRequest: pullRequest, link: pullRequest, date: now)
}

private func run(_ summary: String?) -> RoutineRun { RoutineRun(started: now, finished: now, status: .done, summary: summary) }

let automationAskTests: [(name: String, run: () throws -> Void)] = [
    ("ask: the recommendation is the run's last line, by the usual words or by the button names", {
        let yes = AutomationAsks.recommendation(in: "Small change.\n**Recommendation:** review \u{2014} touches the payout code")
        check(yes == AutomationAsks.Recommendation(verdict: .yes, reason: "touches the payout code"), "\(String(describing: yes))")
        let skip = AutomationAsks.recommendation(in: "Merged already.\nrecommendation: skip - it is merged")
        check(skip == AutomationAsks.Recommendation(verdict: .skip, reason: "it is merged"), "\(String(describing: skip))")
        check(AutomationAsks.recommendation(in: "Recommendation: fix it: a one-line change", yes: "Fix it", no: "Leave it")?.verdict == .yes, "the button's own word")
        check(AutomationAsks.recommendation(in: "Recommendation: leave, not mine", yes: "Fix it", no: "Leave it")?.verdict == .skip, "the other button")
        let unclear = AutomationAsks.recommendation(in: "Recommendation: maybe look at the tests")
        check(unclear?.verdict == nil && unclear?.reason == "maybe look at the tests", "no verdict")
        check(AutomationAsks.recommendation(in: "Nothing to add") == nil && AutomationAsks.recommendation(in: nil) == nil, "none")
        check(AutomationAsks.answer("Small.\nRecommendation: review - ok\n") == "Small.", "the answer without its recommendation")
    }),

    ("ask: the notification says what is recommended, then the first lines of the notes, and asks when there is nothing else", {
        let ask = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer")
        let text = AutomationAsks.notification(for: review(ask), event: event(), run: run("Katia, +34/-16, ACME-5.\nRecommendation: review \u{2014} a payout change"), ask: ask)
        check(text.title == "Reviews: orbit.api #12 Change", text.title)
        check(text.body == "Recommended: Review it \u{2014} a payout change\nKatia, +34/-16, ACME-5.", text.body)
        let skipped = AutomationAsks.notification(for: review(ask), event: event(), run: run("Recommendation: skip"), ask: ask)
        check(skipped.body == "Recommended: Skip", skipped.body)
        check(AutomationAsks.notification(for: review(ask), event: event(), run: run(nil), ask: ask).body == "Waiting for your answer.", "empty")
        let long = AutomationAsks.notification(for: review(ask), event: event(), run: run(String(repeating: "x", count: 600)), ask: ask)
        check(long.body.count == Routines.notificationLimit && long.body.hasSuffix("\u{2026}"), "clipped")
    }),

    ("ask: the first button sends the prompt with the event's fields, the recommendation and the notes, to the assistant or the pull request's agent", {
        let ask = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: "Review {pr_url} by {pr_author}. Advice: {recommendation}\n{answer}")
        let notice = AutomationAsks.notice(for: review(ask), event: event(), run: run("Looks safe.\nRecommendation: review - small"), ask: ask, reminder: "r1")
        var kept = notice
        kept?.eventText = nil
        check(kept == NoticeAsk(routine: "A1", yes: "Review it", no: "Skip", agent: "assistant:work:reviewer",
                                prompt: "Review \(pull) by Katia. Advice: small\nLooks safe.", reminder: "r1", event: event().id,
                                ticket: nil, pullRequest: pull, origin: "Review requested in acme-com/orbit.api", links: [LinkTargets.pullRequest(pull)!]), "\(String(describing: notice))")
        check(notice?.eventText?.contains(event().text) == true, "the event's text is kept for the row")
        var own = ask
        own.agent = ""
        own.prompt = ""
        let fallback = AutomationAsks.notice(for: review(own), event: event(), run: run("Fine."), ask: own, reminder: nil)
        check(fallback?.agent == pull && fallback?.prompt.contains(pull) == true && fallback?.prompt.contains("do not post, approve or comment") == true, "\(String(describing: fallback))")
        check(AutomationAsks.notice(for: review(own), event: event(pullRequest: nil), run: run("Fine."), ask: own, reminder: nil) == nil, "nobody to start")
        var long = ask
        long.prompt = String(repeating: "y", count: 6000)
        check(AutomationAsks.notice(for: review(long), event: event(), run: run("x"), ask: long, reminder: nil)?.prompt.count == AgentInbox.textLimit, "limited to what an agent takes")
    }),

    ("ask: the buttons need names, a place to start, and an assistant that exists", {
        let trigger = AutomationTrigger(kind: .reviewRequested), jira = AutomationTrigger(kind: .jiraAssigned)
        let assistants: Set<String> = ["assistant:work:reviewer"]
        func problem(_ ask: AutomationAsk, _ trigger: AutomationTrigger = trigger) -> String? { AutomationAsks.problem(ask, trigger: trigger, assistants: assistants) }
        check(problem(AutomationAsk()) == nil, "the defaults start the pull request's agent")
        check(problem(AutomationAsk(yes: " ", no: "Skip")) != nil && problem(AutomationAsk(yes: "Go", no: "")) != nil, "names")
        check(problem(AutomationAsk(yes: "Same", no: "same")) != nil, "different names")
        check(problem(AutomationAsk(yes: String(repeating: "a", count: 25), no: "Skip")) != nil, "too long")
        check(problem(AutomationAsk(), jira) != nil, "a ticket has no pull request agent")
        check(problem(AutomationAsk(yes: "Start it", no: "Skip", agent: "assistant:work:reviewer"), jira) == nil, "a ticket with an assistant")
        check(problem(AutomationAsk(agent: "assistant:work:ghost")) != nil, "an assistant that does not exist")
        check(problem(AutomationAsk(agent: pull)) == nil, "a pull request agent by url")
        check(AutomationAsk.defaults(for: .jiraNew).yes == "Start it" && AutomationAsk.defaults(for: .prOpened).yes == "Review it", "defaults by event")
    }),

    ("ask: each pair of button names is a category of its own, and the answers are told apart", {
        let one = NoticeAsk(routine: "A", yes: "Review it", no: "Skip", agent: "x", prompt: "p", reminder: nil)
        var two = one
        two.yes = "Start it"
        check(AutomationAsks.category(one) != AutomationAsks.category(two) && AutomationAsks.category(one) == AutomationAsks.category(yes: "Review it", no: "Skip"), "categories")
        check(Set([AutomationAsks.yesAction, AutomationAsks.noAction, AutomationAsks.openAction]).count == 3, "actions")
        check(AgentAttention.response(action: AgentAttention.stopAction, text: nil) == .stop, "stopping a started run")
    }),

    ("ask: the question is saved with the notification and with the automation, and what was saved before still reads", {
        var notice = AgentNotice(id: "n", title: "t", source: NoticeSource(agent: "main:work"), created: now)
        notice.ask = NoticeAsk(routine: "A", yes: "Review it", no: "Skip", agent: pull, prompt: "p", reminder: "r")
        check(NoticeLogic.decode(NoticeLogic.encode([notice])) == [notice], "the notification keeps its question")
        let old = #"[{"id":"n","title":"t","source":{"agent":"main:work"},"created":"2027-01-15T08:00:00Z","urgency":"normal","state":"shown"}]"#
        check(NoticeLogic.decode(Data(old.utf8)).first?.ask == nil, "an old notification")
        let routine = review()
        check(Routines.decode(Routines.encode([routine])) == [routine], "the automation keeps its question")
        let followUp = try JSONDecoder().decode(AutomationFollowUp.self, from: Data(#"{"notify":true,"remind":false}"#.utf8))
        check(followUp == AutomationFollowUp(notify: true, remind: false, ask: nil), "an old follow-up")
        var state = AutomationState()
        state.answers["A1"] = AskAnswer(title: "t", yes: true, date: now)
        check(AgentInbox.decode(AutomationState.self, from: AgentInbox.encode(state)) == state, "the answer is kept")
        let legacy = #"{"seen":{},"baselined":[],"fired":{},"last":{}}"#
        check(AgentInbox.decode(AutomationState.self, from: Data(legacy.utf8))?.answers.isEmpty == true, "an old state file")
        check(state.pruned(keeping: []).answers.isEmpty && state.pruned(keeping: [routine]).answers.count == 1, "answers of deleted automations go")
    }),

    ("ask: the run is told to end with a recommendation, and the row says what waits and what was chosen", {
        check(Automations.systemNote(review()).contains("Recommendation: review it or Recommendation: skip"), "asked")
        check(!Automations.systemNote(review(nil)).contains("Recommendation"), "not asked")
        let routine = review()
        check(Routines.detail(routine, now: now, waiting: 2).contains("2 waiting for you"), "waiting")
        let answer = AskAnswer(title: "t", yes: false, date: now.addingTimeInterval(-300))
        check(Routines.detail(routine, now: now, answer: answer).contains("skipped"), "skipped")
        check(Routines.detail(routine, now: now, waiting: 1, answer: answer).contains("1 waiting") && !Routines.detail(routine, now: now, waiting: 1, answer: answer).contains("skipped"), "waiting first")
        check(Routines.detail(routine, now: now) == Routines.detail(review(nil), now: now), "nothing asked, nothing said")
    }),

    ("ask: create_automation and update_automation take the question; every event has a triage prompt of its own", {
        let draft = try RoutineRequests.automationDraft(["name": "Reviews", "event": "review_requested", "ask": true, "ask_agent": "assistant:work:reviewer", "remind": true])
        check(draft.followUp?.ask == AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: ""), "\(String(describing: draft.followUp))")
        check(draft.prompt == AutomationTrigger.Kind.reviewRequested.askPrompt, "a triage by default")
        let named = try RoutineRequests.automationDraft(["name": "Tickets", "event": "jira_assigned", "ask_yes": "Work on it"])
        check(named.followUp?.ask?.yes == "Work on it" && named.followUp?.ask?.no == "Skip", "naming a part turns it on")
        check(try RoutineRequests.automationDraft(["name": "Plain", "event": "review_requested"]).followUp?.ask == nil, "off by default")
        check(try RoutineRequests.automationDraft(["name": "Off", "event": "review_requested", "ask": false, "ask_yes": "Go"]).followUp?.ask == nil, "off wins")
        let reply = RoutineRequests.routine(from: named, source: NoticeSource(workspace: "work"), workspaces: ["work"], assistants: [], id: "N", now: now)
        if case .success = reply { check(false, "a ticket needs an assistant to start") }
        let patch = try RoutineRequests.automationPatch(["ask_no": "Later", "ask_agent": "assistant:work:reviewer"])
        let applied = patch.automation?.applied(to: AutomationTrigger(kind: .reviewRequested), followUp: AutomationFollowUp()).1
        check(applied?.ask == AutomationAsk(yes: "Review it", no: "Later", agent: "assistant:work:reviewer", prompt: ""), "\(String(describing: applied))")
        let off = try RoutineRequests.automationPatch(["ask": false]).automation?.applied(to: AutomationTrigger(kind: .reviewRequested), followUp: applied).1
        check(off?.ask == nil, "turned off")
        for kind in AutomationTrigger.Kind.allCases {
            let used = kind.askPrompt.matches(of: #/\{([a-z_]+)\}/#).map { String($0.1) }
            check(used.allSatisfy(kind.fields.contains), "\(kind.rawValue) triage uses \(used.filter { !kind.fields.contains($0) })")
            check(!AutomationAsks.defaultPrompt(for: kind).isEmpty, "\(kind.rawValue) default")
        }
    }),
]
