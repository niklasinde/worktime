import Foundation

/// The agent for one Jira ticket is the topic agent linked to its key; these are the words it starts with.
enum JiraAgents {
    static func systemPrompt(ticket key: String, name: String, folder: String) -> String {
        """
        You are the agent for the Jira ticket \(key) in WorkTime (\u{201C}\(name)\u{201D}). Work on this ticket only.
        Start from the ticket: read it with the worktime jira_issue tool, and the pull requests that name it with github_pr. \
        Your working folder is \(folder). When it is a git repository you may read and change code there for this ticket, but never \
        commit, push or open a pull request unless the user asks you to.
        Jira and GitHub are read-only for you. You cannot post a comment, change a status or edit the ticket, and must never claim you \
        did. When a comment, a status change or a reply is needed, draft it as text in a fenced block for the user to copy, say where \
        it should go, and wait for the user to say it is posted.
        """
    }

    static func pullRequestLine(_ pr: GitHubPR) -> String {
        let checks = pr.checks == .none ? "" : ", checks \(pr.checks.rawValue)"
        return "- \(pr.repo)#\(pr.number) \(pr.title) (\(pr.isDraft ? "draft" : pr.state.rawValue)\(checks)) \(pr.url)"
    }

    /// The prompt waiting in the ticket agent's composer: the ticket as fetched, the pull requests that name it and what to do first.
    static func context(issue: JiraIssue, pullRequests: [GitHubPR], site: String?, now: Date) -> String {
        let linked = pullRequests.isEmpty ? "No pull request names it yet." : pullRequests.map(pullRequestLine).joined(separator: "\n")
        return """
            Work on the Jira ticket \(issue.key). This is a read-only copy of it as it stood just now.

            \(JiraLogic.issueMarkdown(issue, site: site, now: now))
            ## Pull requests that name it
            \(linked)

            Summarise what is needed from me, point out acceptance criteria and open questions in the description and comments, and \
            propose how to approach it. Do not post or change anything in Jira or GitHub.
            """
    }

    /// A ticket as the list shows it, from a freshly fetched issue.
    static func ticket(_ issue: JiraIssue) -> JiraTicket {
        JiraTicket(key: issue.key, summary: issue.summary, status: issue.status, priority: issue.priority, updated: issue.updated,
                   type: issue.type, assignee: issue.assignee)
    }
}
