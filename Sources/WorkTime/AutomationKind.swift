import Foundation

extension AutomationTrigger {
    enum Source: String, CaseIterable, Identifiable, Sendable {
        case slack, github, jira

        var id: String { rawValue }
        var title: String { self == .github ? "GitHub" : rawValue.capitalized }
    }

    /// What a trigger can be narrowed by; each kind uses some of them.
    enum Input: String, Sendable { case place, text, status, fromStatus, jql, pattern }

    /// What starts an automation.
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case slackMessage = "slack_message"
        case slackChannel = "slack_channel"
        case slackKeyword = "slack_keyword"
        case slackReply = "slack_reply"
        case reviewRequested = "review_requested"
        case prOpened = "pr_opened"
        case prUpdated = "pr_updated"
        case ciFailed = "ci_failed"
        case prFeedback = "pr_feedback"
        case prApproved = "pr_approved"
        case prMerged = "pr_merged"
        case prMentioned = "pr_mentioned"
        case jiraAssigned = "jira_assigned"
        case jiraStatus = "jira_status"
        case jiraNew = "jira_new"
        case jiraComment = "jira_comment"

        var id: String { rawValue }

        var source: Source {
            switch self {
            case .slackMessage, .slackChannel, .slackKeyword, .slackReply: .slack
            case .jiraAssigned, .jiraStatus, .jiraNew, .jiraComment: .jira
            default: .github
            }
        }

        /// Fetched on a timer, and only while an automation of the kind is on; the others are handed over by a list the app already follows.
        var polled: Bool {
            switch self {
            case .slackChannel, .slackKeyword, .slackReply, .prOpened, .prUpdated, .jiraAssigned, .jiraStatus, .jiraNew, .jiraComment: true
            default: false
            }
        }

        /// Notifications about it offer to approve or request changes: someone else's pull request waits for a decision.
        var offersReview: Bool {
            switch self {
            case .slackMessage, .slackChannel, .slackKeyword, .slackReply, .reviewRequested, .prOpened, .prUpdated: true
            default: false
            }
        }

        var title: String {
            switch self {
            case .slackMessage: "A Slack mention or direct message to me"
            case .slackChannel: "A new message in a Slack channel"
            case .slackKeyword: "A Slack message with a keyword"
            case .slackReply: "A reply in a Slack thread I wrote in"
            case .reviewRequested: "A review is requested from me"
            case .prOpened: "A pull request is opened in a repository"
            case .prUpdated: "A pull request is updated in a repository"
            case .ciFailed: "Checks fail on my pull request"
            case .prFeedback: "Someone reviews or comments on my pull request"
            case .prApproved: "My pull request is approved"
            case .prMerged: "My pull request is merged"
            case .prMentioned: "I am mentioned on a pull request"
            case .jiraAssigned: "A Jira ticket is assigned to me"
            case .jiraStatus: "A Jira ticket changes status"
            case .jiraNew: "A new Jira ticket is created"
            case .jiraComment: "Someone comments on my Jira ticket"
            }
        }

        /// How the sidebar and the notifications name it.
        var shortTitle: String {
            switch self {
            case .slackMessage: "Slack message"
            case .slackChannel: "Slack channel message"
            case .slackKeyword: "Slack keyword"
            case .slackReply: "Slack thread reply"
            case .reviewRequested: "Review requested"
            case .prOpened: "Pull request opened"
            case .prUpdated: "Pull request updated"
            case .ciFailed: "Checks failed"
            case .prFeedback: "Pull request feedback"
            case .prApproved: "Pull request approved"
            case .prMerged: "Pull request merged"
            case .prMentioned: "Pull request mention"
            case .jiraAssigned: "Jira assigned"
            case .jiraStatus: "Jira status change"
            case .jiraNew: "New Jira ticket"
            case .jiraComment: "Jira comment"
            }
        }

        var inputs: [Input] {
            switch self {
            case .slackMessage, .slackReply: [.place, .text]
            case .slackChannel: [.place, .text, .pattern]
            case .slackKeyword: [.text, .place, .pattern]
            case .jiraAssigned, .jiraNew: [.place, .text, .jql]
            case .jiraStatus: [.place, .status, .fromStatus, .text, .jql]
            default: [.place, .text]
            }
        }

        func title(of input: Input) -> String {
            switch input {
            case .place:
                switch source {
                case .slack: self == .slackChannel ? "Channels" : "Channel or person"
                case .github: "Repository"
                case .jira: "Project"
                }
            case .text:
                switch self {
                case .slackKeyword: "Keywords"
                case .jiraComment: "Comment contains"
                case .jiraAssigned, .jiraStatus, .jiraNew: "Summary contains"
                default: source == .slack ? "Message contains" : "Title contains"
                }
            case .status: "Moves to status"
            case .fromStatus: "Moves from status"
            case .jql: "Also matches JQL"
            case .pattern: "Matches regex"
            }
        }

        /// What the editor says under the fields about where the events come from.
        var note: String? {
            switch self {
            case .slackMessage: "Sees the mentions and direct messages waiting on you, while the notch bar shows Slack."
            case .slackChannel, .slackKeyword: "Searches Slack every few minutes for the last day, while this automation is on."
            case .slackReply: "Reads the threads you wrote in during the last day every few minutes, and fires for the replies of others."
            case .prOpened, .prUpdated: "Searches the repository every few minutes for pull requests by others. A bare name matches a repository the app already lists."
            case .jiraAssigned: "Fires for each open ticket assigned to you that it has not seen."
            case .jiraStatus: "Fires for status changes of the last two days that you did not make yourself. Without a project or JQL it covers tickets assigned to, reported by or watched by you."
            case .jiraNew: "Searches Jira every few minutes for tickets created in the last two days."
            case .jiraComment: "Fires for comments by others on tickets assigned to or reported by you."
            default: nil
            }
        }

        /// What has to be filled in, as the label of its input; nil when every event of the kind is fine.
        var required: Input? {
            switch self {
            case .slackChannel, .prOpened, .prUpdated: .place
            case .slackKeyword: .text
            default: nil
            }
        }

        /// The placeholders a prompt can use for this kind of event.
        var fields: [String] {
            switch source {
            case .slack: ["slack_text", "slack_place", "slack_author", "slack_link", "pr_url", "ticket"]
            case .github:
                ["pr_url", "pr_title", "pr_repo", "pr_number", "pr_author", "ticket"] + (self == .prFeedback ? ["reviewer", "review_state"] : [])
            case .jira: ["ticket", "ticket_title", "status", "from_status", "url", "project", "assignee", "comment", "comment_author"]
            }
        }

        var defaultPrompt: String {
            switch self {
            case .slackMessage, .slackChannel, .slackKeyword:
                "A message in {slack_place} from {slack_author}: {slack_text}\n{slack_link}\n\n"
                    + "If it asks for a review of a pull request, review {pr_url}: read the diff and the code around it and draft a review. "
                    + "Otherwise say in two lines what it asks and what I should do."
            case .slackReply:
                "A reply in a thread I wrote in, in {slack_place} from {slack_author}: {slack_text}\n{slack_link}\n\n"
                    + "Read the thread with slack_thread, then say in two lines what they ask and what I should answer."
            case .reviewRequested:
                "Review {pr_url} ({pr_title}, by {pr_author}). Read the diff and the code around it, then draft the review: "
                    + "a verdict (approve, request changes or needs the author's input), the problems that block it and the small ones."
            case .prOpened:
                "{pr_url} ({pr_title}, by {pr_author}) was opened in {pr_repo}. Read the diff and say in a few lines what it changes, "
                    + "what looks risky and whether it needs my review."
            case .prUpdated:
                "{pr_url} ({pr_title}, by {pr_author}) was updated in {pr_repo}. Read what changed and say in a few lines whether it needs my attention."
            case .ciFailed:
                "The checks failed on my pull request {pr_url} ({pr_title}). Find which check failed and why (read-only: gh pr checks, the logs, the code) "
                    + "and say what to change. Do not push anything."
            case .prFeedback:
                "{reviewer} left feedback ({review_state}) on my pull request {pr_url} ({pr_title}).\n\n"
                    + "Read the discussion (read-only: gh pr view --comments), say what they ask for and draft the replies and the changes. Do not post anything."
            case .prApproved:
                "My pull request {pr_url} ({pr_title}) was approved. Check whether it is ready to merge (checks, conflicts, open threads) and tell me what is left."
            case .prMerged:
                "{pr_url} ({pr_title}) was merged. Say what comes next for it: the ticket {ticket}, the release note, anything to deploy or follow up."
            case .prMentioned:
                "I was mentioned on {pr_url} ({pr_title}). Read the discussion and tell me what is asked of me and what to answer."
            case .jiraAssigned:
                "{ticket} ({ticket_title}) was assigned to me: {url}. Read it with jira_issue and say what is asked, what is unclear and how I would start."
            case .jiraStatus:
                "{ticket} ({ticket_title}) moved from {from_status} to {status}: {url}. Read it with jira_issue and say what needs doing next on my side."
            case .jiraNew:
                "A new ticket {ticket} ({ticket_title}) was created in {project}: {url}. Read it with jira_issue and say what it is, how urgent it looks and what it needs."
            case .jiraComment:
                "{comment_author} commented on {ticket} ({ticket_title}): {comment}\n{url}\n\n"
                    + "Read the ticket with jira_issue and say what they ask and what I should answer. Do not post anything."
            }
        }

        /// The prompt of a run that only looks at the event and recommends, when the user is asked what to do next.
        var askPrompt: String {
            switch source {
            case .slack:
                "A message in {slack_place} from {slack_author}: {slack_text}\n{slack_link}\n\n"
                    + "If it asks for a review of a pull request ({pr_url}), look at it without reviewing it (read-only: gh pr view {pr_url} --json state,isDraft,author,title,additions,deletions,reviewDecision) "
                    + "and say who asked, how big it is and the ticket it belongs to. If it is merged, closed or a draft, or the message asks for nothing, recommend skipping."
            case .github:
                "{pr_url} ({pr_title}, by {pr_author}) needs a look. Do not review it yet. Read what it is (read-only: gh pr view {pr_url} "
                    + "--json state,isDraft,author,title,additions,deletions,reviewDecision) and say in a few lines who wrote it, how big it is and the ticket {ticket}. "
                    + "If it is merged, closed or a draft, recommend skipping."
            case .jira:
                "{ticket} ({ticket_title}): {url}. Read it with jira_issue and say in a few lines what it asks, how big it looks and whether it is worth starting now."
            }
        }

        /// The prefix of its event ids. The first two kinds keep the prefixes saved before there were more.
        var idPrefix: String {
            switch self {
            case .slackMessage: "slack"
            case .reviewRequested: "review"
            default: rawValue
            }
        }
    }
}
