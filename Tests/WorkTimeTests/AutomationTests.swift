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
        var source = NoticeSource(agent: Routines.prefix + UUID().uuidString, workspace: "work")
        source.reviewing = true
        let review = AgentNotice(id: "n1", title: "t", link: "https://github.com/quiddly-com/finq.api/pull/12", source: source, created: now)
        check(NoticeLogic.isReview(review), "a routine's run about a pull request")
        source.reviewing = nil
        check(!NoticeLogic.isReview(AgentNotice(id: "n4", title: "t", link: "https://github.com/quiddly-com/finq.api/pull/12", source: source, created: now)), "one about my own pull request")
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

    ("automations: every kind has a prompt that only uses its own placeholders, and a way to fill it in", {
        for kind in AutomationTrigger.Kind.allCases {
            let used = kind.defaultPrompt.matches(of: #/\{([a-z_]+)\}/#).map { String($0.1) }
            check(used.allSatisfy(kind.fields.contains), "\(kind.rawValue) uses \(used.filter { !kind.fields.contains($0) })")
            check(!kind.inputs.isEmpty && kind.required.map(kind.inputs.contains) ?? true, "\(kind.rawValue) inputs")
            check(Automations.label(AutomationTrigger(kind: kind)).hasPrefix(kind.shortTitle), "\(kind.rawValue) label")
        }
        check(Set(AutomationTrigger.Kind.allCases.map(\.idPrefix)).count == AutomationTrigger.Kind.allCases.count, "ids of one kind never look like another's")
        check(AutomationTrigger.Kind.slackMessage.idPrefix == "slack" && AutomationTrigger.Kind.reviewRequested.idPrefix == "review", "the saved ids keep their prefixes")
        check(AutomationTrigger.Kind.allCases.filter(\.polled).allSatisfy { [.slack, .jira].contains($0.source) || [.prOpened, .prUpdated].contains($0) }, "only searches are polled")
    }),

    ("automations: a trigger saved before the new filters still reads, and the new ones survive their file", {
        let old = Data(#"{"kind":"slack_message","place":"reviews","text":"","needsPullRequest":true}"#.utf8)
        let read = try JSONDecoder().decode(AutomationTrigger.self, from: old)
        check(read == AutomationTrigger(kind: .slackMessage, place: "reviews", needsPullRequest: true), "\(read)")
        let trigger = AutomationTrigger(kind: .jiraStatus, place: "QDLY", text: "x", status: "Done", fromStatus: "Review", jql: "labels = a", pattern: "^x")
        check(try JSONDecoder().decode(AutomationTrigger.self, from: JSONEncoder().encode(trigger)) == trigger, "round trip")
    }),

    ("automations: triggers that would match everything or cannot work are refused", {
        check(Automations.problem(AutomationTrigger(kind: .slackChannel)) != nil && Automations.problem(AutomationTrigger(kind: .slackChannel, place: "#reviews")) == nil, "channel")
        check(Automations.problem(AutomationTrigger(kind: .slackKeyword)) != nil && Automations.problem(AutomationTrigger(kind: .slackKeyword, text: "outage")) == nil, "keyword")
        check(Automations.problem(AutomationTrigger(kind: .prOpened)) != nil && Automations.problem(AutomationTrigger(kind: .prUpdated, place: "finq.api")) == nil, "repository")
        check(Automations.problem(AutomationTrigger(kind: .jiraNew)) != nil, "every new ticket")
        check(Automations.problem(AutomationTrigger(kind: .jiraNew, place: "ISD")) == nil && Automations.problem(AutomationTrigger(kind: .jiraNew, jql: "labels = a")) == nil, "a project or a query")
        check(Automations.problem(AutomationTrigger(kind: .jiraStatus)) == nil && Automations.problem(AutomationTrigger(kind: .ciFailed)) == nil, "mine by default")
        check(Automations.problem(AutomationTrigger(kind: .slackChannel, place: "x", pattern: "(")) != nil, "a regex that does not compile")
        check(Automations.problem(AutomationTrigger(kind: .ciFailed, needsPullRequest: true)) != nil, "only Slack needs a pull request")
    }),

    ("automations: status, regex and text filters narrow an event", {
        let event = AutomationEvent(id: "j", kind: .jiraStatus, title: "t", place: "QDLY", text: "Fix the invoice export",
                                    fields: ["status": "Ready for review", "from_status": "In progress"], pullRequest: nil, link: nil, date: now)
        check(Automations.matches(AutomationTrigger(kind: .jiraStatus, place: "qdly", status: "review, done", fromStatus: "progress"), event), "to and from")
        check(!Automations.matches(AutomationTrigger(kind: .jiraStatus, status: "Done"), event), "another status")
        check(!Automations.matches(AutomationTrigger(kind: .jiraStatus, fromStatus: "Backlog"), event), "another from")
        check(Automations.matches(AutomationTrigger(kind: .jiraStatus, pattern: "^fix .* export$"), event), "regex")
        check(!Automations.matches(AutomationTrigger(kind: .jiraStatus, pattern: "^export"), event), "regex that does not")
        check(Automations.label(AutomationTrigger(kind: .jiraStatus, place: "QDLY", status: "Done", fromStatus: "Review")) == "Jira status change in QDLY from Review to Done", Automations.label(AutomationTrigger(kind: .jiraStatus, place: "QDLY", status: "Done", fromStatus: "Review")))
    }),

    ("automations: the pull request lists make the events, and only for the lists that loaded", {
        func pr(_ number: Int, repo: String = "quiddly-com/finq.api", state: GitHubPR.State = .open, checks: GitHubPR.Checks = .none, review: GitHubPR.Review? = nil,
                author: String = "anna", activity: GitHubActivity? = nil) -> GitHubPR {
            GitHubPR(url: "https://github.com/\(repo)/pull/\(number)", number: number, title: "QDLY-\(number): T", repo: repo, state: state, updated: now, review: review,
                     checks: checks, author: author, activity: activity)
        }
        let robot = GitHubActivity.Actor(login: "dependabot", isBot: true), elin = GitHubActivity.Actor(login: "elin"), me = GitHubActivity.Actor(login: "me")
        let activity = GitHubActivity(me: "me", reviews: [.init(actor: elin, state: "CHANGES_REQUESTED", date: now), .init(actor: me, state: "COMMENTED", date: now),
                                                          .init(actor: robot, state: "COMMENTED", date: now)], lastComment: .init(actor: elin, date: now.addingTimeInterval(60)),
                                      lastCommit: now.addingTimeInterval(-60))
        let lists: [GitHubKind: [GitHubPR]] = [
            .created: [pr(1, checks: .failed, author: "me", activity: activity), pr(2, state: .merged, author: "me"), pr(3, review: .approved, author: "me")],
            .mentioned: [pr(4, activity: GitHubActivity(me: "me")), pr(5, author: "me", activity: GitHubActivity(me: "me"))],
        ]
        let events = Automations.githubEvents(lists)
        check(events[.reviewRequested] == nil, "a list that did not load makes no events, not empty ones")
        check(events[.ciFailed]?.map(\.id) == ["ci_failed:https://github.com/quiddly-com/finq.api/pull/1:\(Int(now.timeIntervalSince1970) - 60)"], "\(String(describing: events[.ciFailed]?.map(\.id)))")
        check(events[.prMerged]?.map(\.fields["pr_number"]) == ["2"] && events[.prApproved]?.map(\.fields["pr_number"]) == ["3"], "merged and approved")
        check(events[.prMentioned]?.map(\.fields["pr_number"]) == ["4"], "my own pull request is not a mention")
        let feedback = events[.prFeedback] ?? []
        check(feedback.map(\.fields["reviewer"]) == ["elin", "elin"] && feedback.first?.fields["review_state"] == "changes requested" && feedback.last?.fields["review_state"] == "comment",
              "\(feedback.map(\.id))")
        check(feedback.allSatisfy { $0.pullRequest == "https://github.com/quiddly-com/finq.api/pull/1" }, "they are about the pull request")
        check(Automations.githubEvents([.reviewRequested: []])[.reviewRequested]?.isEmpty == true, "an empty list that loaded is a first look")
        let repo = Automations.repositoryEvents([pr(7), pr(8, state: .closed)])
        check(repo[.prOpened]?.count == 1 && repo[.prUpdated]?.first?.id.hasPrefix("pr_updated:https://github.com/quiddly-com/finq.api/pull/7:") == true, "\(repo)")
        check(Automations.repositories("finq.api, other/name, nope", known: ["quiddly-com/finq.admin-ui", "quiddly-com/finq.api"]) == ["quiddly-com/finq.api", "other/name"], "names")
        check(Automations.repositorySearch("a/b").terms.contains("repo:a/b is:pr is:open -author:@me"), Automations.repositorySearch("a/b").terms)
    }),

    ("automations: each Jira event kind searches its own tickets", {
        check(Automations.jiraQuery(AutomationTrigger(kind: .jiraAssigned)) == "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", Automations.jiraQuery(AutomationTrigger(kind: .jiraAssigned)))
        check(Automations.jiraQuery(AutomationTrigger(kind: .jiraNew, place: "ISD, QDLY")) == "project in (ISD, QDLY) AND created >= -2d ORDER BY updated DESC", Automations.jiraQuery(AutomationTrigger(kind: .jiraNew, place: "ISD, QDLY")))
        let status = Automations.jiraQuery(AutomationTrigger(kind: .jiraStatus))
        check(status.contains("updated >= -2d") && status.contains("watcher = currentUser()"), status)
        let own = Automations.jiraQuery(AutomationTrigger(kind: .jiraStatus, place: "QPB", jql: "labels = a ORDER BY created DESC"))
        check(own == "(labels = a) AND project in (QPB) AND updated >= -2d ORDER BY created DESC", own)
        check(Automations.jiraQuery(AutomationTrigger(kind: .jiraNew, place: "x\" OR 1=1")).hasPrefix("created") , "a project that is not a key is dropped: \(Automations.jiraQuery(AutomationTrigger(kind: .jiraNew, place: "x\" OR 1=1")))")
        check(Automations.jiraBody(jql: "j", kind: .jiraStatus)["expand"] as? String == "changelog" && Automations.jiraBody(jql: "j", kind: .jiraNew)["expand"] == nil, "only status changes ask for the changelog")
    }),

    ("automations: Jira answers become assignments, new tickets, status changes and comments, leaving out my own", {
        func iso(_ offset: TimeInterval) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
            return formatter.string(from: now.addingTimeInterval(offset))
        }
        let json = """
        {"issues":[{"key":"QDLY-7","fields":{"summary":"Export fails","status":{"name":"In review"},"assignee":{"accountId":"me","displayName":"Niklas"},
          "created":"\(iso(-86400))","updated":"\(iso(-60))",
          "comment":{"comments":[
            {"id":"10","author":{"accountId":"anna","displayName":"Anna"},"created":"\(iso(-300))","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Can you check this?"}]}]}},
            {"id":"11","author":{"accountId":"me","displayName":"Niklas"},"created":"\(iso(-200))","body":"mine"},
            {"id":"12","author":{"accountId":"anna","displayName":"Anna"},"created":"\(iso(-4 * 86400))","body":"old"}]}},
         "changelog":{"histories":[
            {"id":"90","created":"\(iso(-400))","author":{"accountId":"anna","displayName":"Anna"},"items":[{"field":"status","fromString":"In progress","toString":"In review"},{"field":"assignee","fromString":"a","toString":"b"}]},
            {"id":"91","created":"\(iso(-300))","author":{"accountId":"me","displayName":"Niklas"},"items":[{"field":"status","fromString":"Open","toString":"In progress"}]},
            {"id":"92","created":"\(iso(-5 * 86400))","author":{"accountId":"anna","displayName":"Anna"},"items":[{"field":"status","fromString":"Open","toString":"Old"}]}]}},
         {"key":"ISD-9","fields":{"summary":"Slow page","status":{"name":"Open"},"assignee":null,"created":"\(iso(-3600))","updated":"\(iso(-3600))"}}]}
        """
        func events(_ kind: AutomationTrigger.Kind) throws -> [AutomationEvent] {
            try Automations.jiraEvents(Data(json.utf8), kind: kind, site: "acme.atlassian.net", me: "me", now: now)
        }
        let assigned = try events(.jiraAssigned)
        check(assigned.map(\.id) == ["jira_assigned:QDLY-7"] && assigned.first?.fields["url"] == "https://acme.atlassian.net/browse/QDLY-7" && assigned.first?.place == "QDLY", "\(assigned)")
        check(try events(.jiraNew).map(\.id) == ["jira_new:QDLY-7", "jira_new:ISD-9"], "new")
        let status = try events(.jiraStatus)
        check(status.map(\.id) == ["jira_status:QDLY-7:90"] && status.first?.fields["from_status"] == "In progress" && status.first?.fields["status"] == "In review", "\(status.map(\.id)): not mine, not old, only the status item")
        let comments = try events(.jiraComment)
        check(comments.map(\.id) == ["jira_comment:QDLY-7:10"] && comments.first?.text == "Can you check this?" && comments.first?.fields["comment_author"] == "Anna", "\(comments)")
        check(Automations.matches(AutomationTrigger(kind: .jiraComment, text: "check"), comments[0]) && !Automations.matches(AutomationTrigger(kind: .jiraComment, place: "ISD"), comments[0]), "filters")
        check((try? Automations.jiraEvents(Data("nope".utf8), kind: .jiraNew, site: "x", me: "", now: now)) == nil, "an answer that is not Jira's is an error, not no events")
        let prompt = Automations.prompt(AutomationTrigger.Kind.jiraStatus.defaultPrompt, event: status[0])
        check(prompt.contains("QDLY-7 (Export fails) moved from In progress to In review") && prompt.contains("https://acme.atlassian.net/browse/QDLY-7"), prompt)
    }),

    ("automations: Slack searches for a channel, a keyword and the threads the user wrote in", {
        let day = Calendar(identifier: .gregorian)
        var calendar = day
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func queries(_ trigger: AutomationTrigger) -> [String] { Automations.slackQueries(trigger, now: now, calendar: calendar) }
        check(queries(AutomationTrigger(kind: .slackChannel, place: "#reviews, dev, @anna", text: "pr")) == ["in:#reviews \"pr\" after:2027-01-14", "in:#dev \"pr\" after:2027-01-14", "from:@anna \"pr\" after:2027-01-14"], "\(queries(AutomationTrigger(kind: .slackChannel, place: "#reviews, dev, @anna", text: "pr")))")
        check(queries(AutomationTrigger(kind: .slackChannel, place: "dev", text: "a, b")) == ["in:#dev after:2027-01-14"], "several words are matched here, not searched")
        check(queries(AutomationTrigger(kind: .slackKeyword, text: "outage, \"down\"")) == ["\"outage\" after:2027-01-14", "\"down\" after:2027-01-14"], "keywords")
        check(queries(AutomationTrigger(kind: .slackKeyword, place: "ops, dev", text: "outage")) == ["\"outage\" in:#ops after:2027-01-14", "\"outage\" in:#dev after:2027-01-14"], "keyword in channels")
        check(queries(AutomationTrigger(kind: .slackReply)) == ["is:thread from:me after:2027-01-14"], "replies")
        check(queries(AutomationTrigger(kind: .slackChannel, place: "a,b,c,d,e,f,g,h")).count == Automations.slackQueryLimit, "capped")
        check(queries(AutomationTrigger(kind: .slackMessage, place: "x")).isEmpty, "mentions come from the app's own list")

        let me = SlackIdentity(userID: "UME", user: "niklas", teamID: "T1", team: "Acme", url: "https://acme.slack.com/")
        let found = [message("deploy done", author: "anna"), message("my own", author: "niklas", ts: "1800000001.000100")]
        let events = Automations.slackSearchEvents(found, kind: .slackChannel, me: me, workspace: me.url)
        check(events.map(\.id) == ["slack_channel:C1-1800000000.000100"] && events.first?.kind == .slackChannel && events.first?.fields["slack_author"] == "anna", "\(events)")

        func mine(_ ts: String, _ link: String) -> SlackMessage {
            SlackMessage(kind: .mention, teamID: "T1", channelID: "C01ABCDEF", place: "#dev", author: "niklas", text: "q", ts: ts, permalink: link)
        }
        let threads = Automations.slackThreads([mine("1800000050.000100", "https://acme.slack.com/archives/C01ABCDEF/p1800000050000100?thread_ts=1800000000.000100"),
                                                mine("1800000060.000100", "https://acme.slack.com/archives/C01ABCDEF/p1800000060000100?thread_ts=1800000000.000100"),
                                                mine("1800000070.000100", "https://acme.slack.com/archives/C01ABCDEF/p1800000070000100")])
        check(threads.map(\.link.root) == ["1800000000.000100", "1800000070.000100"], "one per thread: \(threads.map(\.link.root))")
        guard threads.count == 2 else { return }
        let replies = Automations.slackReplyEvents([SlackRawMessage(ts: "1800000000.000100", text: "root", user: "UME"), SlackRawMessage(ts: "1800000100.000100", text: "ok?", user: "UANNA"),
                                                    SlackRawMessage(ts: "1800000200.000100", text: "me too", user: "UME")], root: threads[0].root, link: threads[0].link,
                                                   names: ["UANNA": "Anna"], me: me, workspace: me.url, now: now)
        check(replies.map(\.id) == ["slack_reply:C01ABCDEF-1800000100.000100"] && replies.first?.fields["slack_author"] == "Anna" && replies.first?.place == "#dev", "\(replies)")
        check(replies.first?.link == "https://acme.slack.com/archives/C01ABCDEF/p1800000100000100", "\(String(describing: replies.first?.link))")
    }),

    ("automations: reminders and notifications fit the kind of event", {
        let pr = pullRequest(5, title: "QDLY-5: Fix")
        func reminder(_ kind: AutomationTrigger.Kind) -> String? { Automations.reminder(for: Automations.pullRequestEvent(pr, kind: kind))?.title }
        check(reminder(.ciFailed) == "Fix the checks on finq.api #5: QDLY-5: Fix" && reminder(.prApproved) == "Merge finq.api #5: QDLY-5: Fix", "\(String(describing: reminder(.ciFailed)))")
        check(reminder(.prOpened) == "Decide on finq.api #5: QDLY-5: Fix" && reminder(.prFeedback) == "Answer the review on finq.api #5: QDLY-5: Fix", "decide and answer")
        let json = Data(#"{"issues":[{"key":"ISD-9","fields":{"summary":"Slow page","status":{"name":"Open"},"created":"2027-01-15T07:00:00.000+0000"}}]}"#.utf8)
        let ticket = try Automations.jiraEvents(json, kind: .jiraNew, site: "acme.atlassian.net", me: "me", now: now)[0]
        let made = Automations.reminder(for: ticket)
        check(made?.title == "Triage ISD-9: Slow page" && made?.source.kind == .jira && made?.source.reference == "ISD-9", "\(String(describing: made))")
        check(Automations.noticeLink(for: ticket) == "https://acme.atlassian.net/browse/ISD-9" && Automations.noticeLink(for: slackEvent("hi")) == nil, "links")
        check(Automations.noticeLink(for: Automations.pullRequestEvent(pr, kind: .prMerged)) == pr.url, "a pull request")
        check(AutomationTrigger.Kind.allCases.filter(\.offersReview).allSatisfy { [.slack].contains($0.source) || [.reviewRequested, .prOpened, .prUpdated].contains($0) }, "review actions only for someone else's work")
        check(Routines.systemPrompt(automation(AutomationTrigger(kind: .jiraNew, place: "ISD")), base: nil).contains("comment on, move or assign a ticket"), "the draft rule covers tickets")
    }),

    ("automations: queued events and the baseline survive their file, and turning automations back on starts over", {
        var state = AutomationState()
        let event = Automations.pullRequestEvent(pullRequest(1))
        state.queued["A1"] = [event]
        state.baselined.insert("A1")
        state.seen["A1"] = ["x"]
        check(try AgentInbox.decode(AutomationState.self, from: AgentInbox.encode(state)) == state, "round trip")
        let old = Data(#"{"seen":{},"baselined":[],"fired":{},"last":{}}"#.utf8)
        check(AgentInbox.decode(AutomationState.self, from: old)?.queued.isEmpty == true, "a state saved before queues")
        var copy = state
        copy.rebaselineAll()
        check(copy.queued.isEmpty && copy.baselined.isEmpty && copy.seen.isEmpty, "all of it")
        check(state.pruned(keeping: []).queued.isEmpty && state.pruned(keeping: [automation(AutomationTrigger(kind: .reviewRequested))]).queued["A1"]?.count == 1, "a deleted automation's queue goes")
        UserDefaults.standard.removeObject(forKey: Automations.enabledKey)
        check(Automations.enabled, "on until turned off")
        UserDefaults.standard.set(false, forKey: Automations.enabledKey)
        check(!Automations.enabled, "off")
        UserDefaults.standard.removeObject(forKey: Automations.enabledKey)
    }),

    ("automations: create_automation and update_automation take the new filters", {
        let draft = try RoutineRequests.automationDraft(["name": "Status", "event": "jira_status", "place": "QDLY", "status": "Done", "from_status": "Review", "jql": "labels = a", "pattern": "x"])
        check(draft.trigger == AutomationTrigger(kind: .jiraStatus, place: "QDLY", status: "Done", fromStatus: "Review", jql: "labels = a", pattern: "x") && draft.prompt == AutomationTrigger.Kind.jiraStatus.defaultPrompt, "\(String(describing: draft.trigger))")
        let patch = try RoutineRequests.automationPatch(["status": "Closed", "from_status": "", "pattern": ""])
        let applied = patch.automation?.applied(to: draft.trigger, followUp: nil).0
        check(applied == AutomationTrigger(kind: .jiraStatus, place: "QDLY", status: "Closed", jql: "labels = a"), "\(String(describing: applied))")
        check(RoutineRequests.triggerKinds.count == AutomationTrigger.Kind.allCases.count && RoutineRequests.triggerKinds.contains("slack_reply"), "every kind can be asked for")
    }),
]

private extension Routine {
    func with(trigger: AutomationTrigger?) -> Routine {
        var copy = self
        copy.trigger = trigger
        return copy
    }
}
