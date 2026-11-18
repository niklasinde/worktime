import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let one = "https://github.com/acme/orbit.api/pull/12"
private let two = "https://github.com/acme/orbit.api/pull/13"
private let at = Date(timeIntervalSince1970: 1_792_300_000)

private func draft(pr: String, sha: String = "0123456") -> ReviewDraft {
    ReviewDraft(pr: pr, sha: sha, verdict: .approve, summary: "Fine.", comments: [])
}

private func review(_ id: String, _ drafts: [ReviewDraft]) -> AgentNotice {
    ReviewNotices.notice(drafts: drafts, agent: "assistant:work:reviewer", agentTitle: "Reviewer", id: id, now: at)
}

private func question(_ id: String, pr: String) -> AgentNotice {
    AgentNotice(id: id, title: "Start the fix?", link: pr, source: NoticeSource(agent: "assistant:work:fixer"), created: at,
                ask: NoticeAsk(routine: "r", yes: "Yes", no: "No", agent: pr, prompt: "go"))
}

private func reminder(_ id: String, source: ReminderSource?, by agent: String? = "assistant:work:reviewer") -> Reminder {
    Reminder(id: id, title: "Look at it", created: at, source: source, addedBy: agent)
}

let closedPullRequestTests: [(name: String, run: () throws -> Void)] = [
    ("closed pull requests: drafts of a merged pull request go, a draft of an open one stays, one in a set leaves the rest", {
        let merged = draft(pr: one), open = draft(pr: two)
        let states: [String: GitHubPR.State] = [one: .merged, two: .open]
        let result = ClosedPullRequests.resolution(notices: [review("single", [merged]), review("set", [merged, open]), review("kept", [open])],
                                                   reminders: [], states: states)
        check(result.drafts == [merged, merged] && result.notices.isEmpty && result.reminders.isEmpty, "\(result)")
        check(ClosedPullRequests.resolution(notices: [review("a", [merged])], reminders: [], states: [one: .closed]).drafts == [merged], "closed without merging")
        check(ClosedPullRequests.resolution(notices: [review("a", [merged])], reminders: [], states: [:]).isEmpty, "unknown is taken as open")
        check(ClosedPullRequests.resolution(notices: [review("a", [draft(pr: one, sha: "9999999")])], reminders: [], states: [one: .open]).isEmpty, "a reopened one with a new draft shows")
    }),

    ("closed pull requests: questions and review notices about it go, other notices stay", {
        let ask = question("ask", pr: one)
        let plain = AgentNotice(id: "plain", title: "CI passed", link: one, source: NoticeSource(agent: "k"), created: at)
        let urgent = AgentNotice(id: "urgent", title: "Needs your decision", link: one, urgency: .high, source: NoticeSource(agent: "k"), created: at)
        let result = ClosedPullRequests.resolution(notices: [ask, plain, urgent, question("open", pr: two)], reminders: [], states: [one: .merged, two: .open])
        check(result.notices == ["ask", "urgent"], "\(result.notices)")
        var several = question("several", pr: one)
        several.ask?.pullRequests = [one, two]
        check(ClosedPullRequests.resolution(notices: [several], reminders: [], states: [one: .merged, two: .open]).notices.isEmpty, "one still open")
        check(ClosedPullRequests.resolution(notices: [several], reminders: [], states: [one: .merged, two: .closed]).notices == ["several"], "all closed")
    }),

    ("closed pull requests: only open reminders an agent raised for the pull request are completed", {
        let byAgent = reminder("agent", source: .pullRequest(GitHubLink.Target(repo: "acme/orbit.api", number: 12)))
        let byUrl = reminder("url", source: ReminderSource(kind: .url, reference: one, title: nil))
        let mine = reminder("mine", source: .pullRequest(GitHubLink.Target(repo: "acme/orbit.api", number: 12)), by: nil)
        var done = reminder("done", source: .pullRequest(GitHubLink.Target(repo: "acme/orbit.api", number: 12)))
        done.completed = at
        let other = reminder("other", source: .pullRequest(GitHubLink.Target(repo: "acme/orbit.api", number: 13)))
        let ticket = reminder("ticket", source: .jira(key: "ABC-1"))
        let result = ClosedPullRequests.resolution(notices: [], reminders: [byAgent, byUrl, mine, done, other, ticket], states: [one: .merged, two: .open])
        check(result.reminders == ["agent", "url"], "\(result.reminders)")
    }),

    ("closed pull requests: the addresses to look up are each pull request once", {
        let urls = ClosedPullRequests.urls(notices: [review("a", [draft(pr: one), draft(pr: two)]), question("q", pr: one)],
                                           reminders: [reminder("r", source: .pullRequest(GitHubLink.Target(repo: "acme/orbit.api", number: 12)))])
        check(urls == [one, two], "\(urls)")
        let states = ClosedPullRequests.states(of: [GitHubPR(url: one, number: 12, title: "t", repo: "acme/orbit.api", state: .merged, updated: at)])
        check(states == [one: .merged], "\(states)")
    }),
]
