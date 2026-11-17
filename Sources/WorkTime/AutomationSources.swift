import Combine
import Foundation

/// Hands the automations the events the app already follows: the Slack mentions and direct messages waiting on the user, and the
/// pull requests that ask for their review. Each is handed over once its source has fetched, so an empty list is never mistaken
/// for everything being new.
@MainActor
final class AutomationSources {
    static let shared = AutomationSources()
    private var subscriptions: Set<AnyCancellable> = []

    func start() {
        subscriptions = []
        let slack = SlackModel.shared
        slack.$messages.combineLatest(slack.$fetched)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages, fetched in
                guard fetched != nil else { return }
                self?.hand(kind: .slackMessage, events: Self.slackEvents(messages, workspace: slack.identity?.url))
            }
            .store(in: &subscriptions)
        let github = GitHubModel.shared
        github.$prs.combineLatest(github.$fetched)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prs, fetched in
                guard fetched != nil else { return }
                self?.hand(kind: .reviewRequested, events: Self.reviewEvents(prs[.reviewRequested] ?? []))
            }
            .store(in: &subscriptions)
    }

    private func hand(kind: AutomationTrigger.Kind, events: [AutomationEvent]) {
        RoutineStore.shared.ingest(kind: kind, events: events)
    }

    static func slackEvents(_ messages: [SlackMessage], workspace: String?) -> [AutomationEvent] {
        messages.filter { $0.handled == nil }.map { Automations.slackEvent($0, link: SlackLogic.webLink($0, workspace: workspace)) }
    }

    static func reviewEvents(_ prs: [GitHubPR]) -> [AutomationEvent] {
        prs.filter { $0.state == .open && !$0.isDraft }.map(Automations.pullRequestEvent)
    }
}
