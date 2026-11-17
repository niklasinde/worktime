import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func message(_ text: String, place: String = "#reviews", author: String = "Anna", ts: String = "1800000000.000100") -> SlackMessage {
    SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: place, author: author, text: text, ts: ts, permalink: "https://acme.slack.com/archives/C1/p1800000000000100")
}

private func pullRequest(_ number: Int, repo: String = "quiddly-com/finq.api", title: String = "QDLY-1: Change") -> GitHubPR {
    GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: title, repo: repo, updated: now)
}

private func automation(_ trigger: AutomationTrigger, id: String = "A1", enabled: Bool = true) -> Routine {
    Routine(id: id, name: "Reviewer", prompt: "Review {pr_url}", workspace: "work", schedule: RoutineSchedule(kind: .daily), enabled: enabled, created: now,
            trigger: trigger, followUp: AutomationFollowUp(notify: true, remind: true))
}

private func slackEvent(_ text: String, place: String = "#reviews", ts: String = "1800000000.000100") -> AutomationEvent {
    Automations.slackEvent(message(text, place: place, ts: ts), link: URL(string: "https://acme.slack.com/archives/C1/p1"))
}

let automationTests: [(name: String, run: () throws -> Void)] = [
    ("automations: a slack trigger matches by place and text, any of several, ignoring case", {
        let event = slackEvent("Can someone review https://github.com/quiddly-com/finq.api/pull/12 please")
        check(Automations.matches(AutomationTrigger(kind: .slackMessage, place: "review", text: ""), event), "place contains")
        check(Automations.matches(AutomationTrigger(kind: .slackMessage, place: "dev, REVIEWS", text: "PLEASE"), event), "any of several")
        check(!Automations.matches(AutomationTrigger(kind: .slackMessage, place: "general"), event), "other place")
        check(!Automations.matches(AutomationTrigger(kind: .slackMessage, place: "reviews", text: "urgent"), event), "other text")
        check(!Automations.matches(AutomationTrigger(kind: .reviewRequested), event), "another kind of event")
    }),

    ("automations: needing a pull request matches only messages that mention one", {
        let trigger = AutomationTrigger(kind: .slackMessage, needsPullRequest: true)
        check(Automations.matches(trigger, slackEvent("see quiddly-com/finq.api#12")), "short reference")
        check(Automations.matches(trigger, slackEvent("see https://github.com/quiddly-com/finq.api/pull/12/files")), "link")
        check(!Automations.matches(trigger, slackEvent("lunch?")), "no pull request")
    }),

    ("automations: a slack trigger that matches everything is refused", {
        check(Automations.problem(AutomationTrigger(kind: .slackMessage)) != nil, "empty")
        check(Automations.problem(AutomationTrigger(kind: .slackMessage, place: "reviews")) == nil, "a place")
        check(Automations.problem(AutomationTrigger(kind: .slackMessage, needsPullRequest: true)) == nil, "a pull request")
        check(Automations.problem(AutomationTrigger(kind: .reviewRequested)) == nil, "every review request is fine")
        check(Routines.problem(name: "x", prompt: "y", schedule: RoutineSchedule(kind: .daily), trigger: AutomationTrigger(kind: .slackMessage)) != nil, "through the routine check")
    }),

    ("automations: events carry the fields a prompt can use", {
        let slack = slackEvent("review quiddly-com/finq.api#12 for QDLY-77")
        check(slack.fields["pr_url"] == "https://github.com/quiddly-com/finq.api/pull/12" && slack.pullRequest == slack.fields["pr_url"], "pull request")
        check(slack.fields["ticket"] == "QDLY-77" && slack.fields["slack_place"] == "#reviews" && slack.fields["slack_author"] == "Anna", "\(slack.fields)")
        let review = Automations.pullRequestEvent(pullRequest(9))
        check(review.id == "review:https://github.com/quiddly-com/finq.api/pull/9" && review.fields["pr_number"] == "9" && review.fields["ticket"] == "QDLY-1", "\(review)")
        let prompt = Automations.prompt("Review {pr_url} by {pr_author} {nothing}", event: review)
        check(prompt == "Review https://github.com/quiddly-com/finq.api/pull/9 by someone {nothing}", prompt)
    }),

    ("automations: the first look marks what is there as seen and starts nothing, then each new event fires once", {
        let routine = automation(AutomationTrigger(kind: .reviewRequested))
        let old = Automations.pullRequestEvent(pullRequest(1))
        let first = Automations.plan(kind: .reviewRequested, events: [old], routines: [routine], state: AutomationState(), now: now)
        check(first.fire.isEmpty && first.state.baselined.contains("A1"), "baseline")
        let fresh = Automations.pullRequestEvent(pullRequest(2))
        let second = Automations.plan(kind: .reviewRequested, events: [old, fresh], routines: [routine], state: first.state, now: now)
        check(second.fire == [Automations.Firing(routine: "A1", event: fresh)], "only the new one")
        let third = Automations.plan(kind: .reviewRequested, events: [old, fresh], routines: [routine], state: second.state, now: now)
        check(third.fire.isEmpty, "not again, also after a restart that kept the state")
        let restarted = try? AgentInbox.decode(AutomationState.self, from: AgentInbox.encode(second.state))
        check(restarted == second.state, "the state survives its file")
    }),

    ("automations: turning one off and on again starts from what is there again", {
        var state = AutomationState()
        let routine = automation(AutomationTrigger(kind: .reviewRequested))
        let event = Automations.pullRequestEvent(pullRequest(3))
        state = Automations.plan(kind: .reviewRequested, events: [], routines: [routine], state: state, now: now).state
        check(Automations.plan(kind: .reviewRequested, events: [event], routines: [routine], state: state, now: now).fire.count == 1, "fires")
        state.rebaseline("A1")
        check(Automations.plan(kind: .reviewRequested, events: [event], routines: [routine], state: state, now: now).fire.isEmpty, "baselined again")
    }),

    ("automations: a disabled one, another kind and a filter fire nothing, and the rate cap skips the rest", {
        let reviews = automation(AutomationTrigger(kind: .reviewRequested, place: "finq.api"))
        var state = Automations.plan(kind: .reviewRequested, events: [], routines: [reviews], state: AutomationState(), now: now).state
        let events = (1...10).map { Automations.pullRequestEvent(pullRequest($0)) } + [Automations.pullRequestEvent(pullRequest(99, repo: "quiddly-com/finq.admin-ui"))]
        let plan = Automations.plan(kind: .reviewRequested, events: events, routines: [reviews], state: state, now: now)
        check(plan.fire.count == Automations.runsPerHour && plan.fire.allSatisfy { $0.event.place == "quiddly-com/finq.api" }, "\(plan.fire.count) fired")
        state = plan.state
        let later = Automations.plan(kind: .reviewRequested, events: events, routines: [reviews], state: state, now: now.addingTimeInterval(7200))
        check(later.fire.isEmpty, "the skipped ones are seen, not queued for later")
        let off = automation(AutomationTrigger(kind: .reviewRequested), enabled: false)
        check(Automations.plan(kind: .reviewRequested, events: events, routines: [off], state: AutomationState(), now: now).state == AutomationState(), "disabled")
        let slack = automation(AutomationTrigger(kind: .slackMessage, place: "x"))
        check(Automations.plan(kind: .reviewRequested, events: events, routines: [slack], state: AutomationState(), now: now).state == AutomationState(), "other kind")
    }),

    ("automations: the latest matching event is kept for trying it out", {
        let routine = automation(AutomationTrigger(kind: .slackMessage, place: "reviews"))
        let events = [slackEvent("one", ts: "1800000000.000100"), slackEvent("two", ts: "1800000100.000100"), slackEvent("elsewhere", place: "#x", ts: "1800000200.000100")]
        let state = Automations.plan(kind: .slackMessage, events: events, routines: [routine], state: AutomationState(), now: now).state
        check(state.last["A1"]?.text == "two", "\(String(describing: state.last["A1"]?.text))")
        check(state.pruned(keeping: []).last.isEmpty && state.pruned(keeping: [routine]).last.count == 1, "a deleted automation's state goes")
    }),

    ("automations: an automation never fires on a schedule and shows its trigger", {
        var routine = automation(AutomationTrigger(kind: .reviewRequested, place: "finq.api"))
        check(Routines.armed(routine, now: now).nextRun == nil, "no next run")
        routine.nextRun = now.addingTimeInterval(-600)
        check(Routines.tick([routine], now: now, running: []).fire.isEmpty, "never due")
        let text = Routines.detail(routine, now: now)
        check(text.hasPrefix("Review requested in finq.api") && text.hasSuffix("not run yet"), text)
        check(Routines.systemPrompt(routine, base: nil).contains("Never approve"), "the draft rule is in its instructions")
        check(!Routines.systemPrompt(automation(AutomationTrigger(kind: .reviewRequested)).with(trigger: nil), base: nil).contains("Never approve"), "a routine has no such note")
    }),

    ("automations: they are saved with their trigger and follow-up, and an old routines file still reads", {
        let routine = automation(AutomationTrigger(kind: .slackMessage, place: "reviews", needsPullRequest: true))
        let back = Routines.decode(Routines.encode([routine]))
        check(back == [routine] && back.first?.followUp?.remind == true, "round trip")
        let old = Routine(id: "R", name: "Sweep", prompt: "p", workspace: "work", schedule: RoutineSchedule(kind: .daily), created: now)
        check(Routines.decode(Routines.encode([old])).first?.trigger == nil, "a routine has none")
    }),

    ("automations: a finished run for a pull request makes the notification and the reminder to decide", {
        let routine = automation(AutomationTrigger(kind: .reviewRequested))
        let event = Automations.pullRequestEvent(pullRequest(12, title: "Add the thing"))
        let run = RoutineRun(started: now, finished: now, status: .done, summary: "Request changes: the migration has no downgrade.\nSmall: a typo.")
        let notice = Automations.notification(for: routine, event: event, run: run)
        check(notice.title == "Reviewer: finq.api #12 Add the thing" && notice.body.hasPrefix("Request changes"), "\(notice)")
        let reminder = Automations.reminder(for: event)
        check(reminder?.title == "Decide on finq.api #12: Add the thing" && reminder?.source == .pullRequest(GitHubLink.Target(repo: "quiddly-com/finq.api", number: 12)), "\(String(describing: reminder))")
        let slack = Automations.reminder(for: slackEvent("anyone?"))
        check(slack?.source.kind == .slack && slack?.title == "Answer #reviews: anyone?", "\(String(describing: slack))")
    }),

    ("automations: a notification from an automation about a pull request offers the review actions", {
        let source = NoticeSource(agent: Routines.prefix + UUID().uuidString, workspace: "work")
        let review = AgentNotice(id: "n1", title: "t", link: "https://github.com/quiddly-com/finq.api/pull/12", source: source, created: now)
        check(NoticeLogic.isReview(review), "a routine's run about a pull request")
        check(!NoticeLogic.isReview(AgentNotice(id: "n2", title: "t", link: "https://github.com/quiddly-com/finq.api/pull/12", source: NoticeSource(agent: "main:work"), created: now)), "another agent's")
        check(!NoticeLogic.isReview(AgentNotice(id: "n3", title: "t", link: source.agent, source: source, created: now)), "one linking its own agent")
    }),

    ("automations: create_automation makes one that waits for events, update changes the trigger, and the lists keep them apart", {
        let workspaces = ["work"]
        func ask(_ action: RoutineRequest.Action, draft: RoutineDraft? = nil, patch: RoutinePatch? = nil, routine: String? = nil, in routines: [Routine] = []) -> (reply: NoticeReply, change: RoutineChange?) {
            RoutineRequests.handle(RoutineRequest(id: "q", action: action, draft: draft, patch: patch, routine: routine, enabled: nil, source: NoticeSource(workspace: "work"), created: now),
                                   routines: routines, workspaces: workspaces, assistants: [], now: now, newID: { "NEW" })
        }
        let draft = try RoutineRequests.automationDraft(["name": "Reviewer", "event": "review_requested", "place": "finq.api", "remind": true])
        check(draft.prompt == AutomationTrigger.Kind.reviewRequested.defaultPrompt && draft.followUp == AutomationFollowUp(notify: true, remind: true), "defaults")
        let created = ask(.create, draft: draft)
        guard case .save(let made)? = created.change else { return check(false, "saved: \(created.reply.message)") }
        check(made.trigger == AutomationTrigger(kind: .reviewRequested, place: "finq.api") && made.nextRun == nil && made.isAutomation, "\(made)")
        check(ask(.create, draft: draft, in: [made]).change == nil, "the same one is not made twice")
        check(ask(.create, draft: try RoutineRequests.automationDraft(["name": "x", "event": "slack_message"])).reply.ok == false, "a Slack one that matches everything")
        let patch = try RoutineRequests.automationPatch(["place": "finq.admin-ui", "contains": "QDLY", "notify": false])
        guard case .save(let changed)? = ask(.update, patch: patch, routine: "NEW", in: [made]).change else { return check(false, "updated") }
        check(changed.trigger == AutomationTrigger(kind: .reviewRequested, place: "finq.admin-ui", text: "QDLY") && changed.followUp == AutomationFollowUp(notify: false, remind: true), "\(changed)")
        let plain = Routine(id: "R", name: "Sweep", prompt: "p", workspace: "work", schedule: RoutineSchedule(kind: .daily), created: now)
        check(ask(.listAutomations, in: [made, plain]).reply.message.contains("Reviewer") && !ask(.listAutomations, in: [made, plain]).reply.message.contains("Sweep"), "automations")
        check(ask(.list, in: [made, plain]).reply.message.contains("Sweep") && !ask(.list, in: [made, plain]).reply.message.contains("Reviewer"), "routines")
    }),
]

private extension Routine {
    func with(trigger: AutomationTrigger?) -> Routine {
        var copy = self
        copy.trigger = trigger
        return copy
    }
}
