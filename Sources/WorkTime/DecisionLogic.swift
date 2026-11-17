import Foundation

/// Decisions are the things that wait for the user's answer: an automation's question, a high-urgency result and an agent's approval.
/// They stay in sight until answered, dismissed or taken back.
enum Decisions {
    static let keepKey = "decisionsKeepOnScreen"
    static let dropDownKey = "decisionsDropDown"
    /// When a notification that was swept away is shown again, counted from when it first came: after 10 and 30 minutes, then an hour.
    static let repostAfter: [TimeInterval] = [600, 1800, 3600]

    static func keepOnScreen(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: keepKey) as? Bool ?? true }

    static func dropsDown(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: dropDownKey) as? Bool ?? true }

    /// A notification that asks something or reports something important, so it is not done with until the user has dealt with it.
    static func needsAnswer(_ notice: AgentNotice) -> Bool {
        notice.state != .scheduled && (notice.ask != nil || notice.urgency == .high)
    }

    /// The ones waiting, newest first.
    static func waiting(_ notices: [AgentNotice]) -> [AgentNotice] {
        notices.filter(needsAnswer).sorted { $0.date > $1.date }
    }

    /// Whether the notch bar drops down now: something new waits, the user is in none of the app's windows, and the setting is on.
    static func shouldDrop(waiting: [String], dropped: Set<String>, enabled: Bool, appActive: Bool) -> Bool {
        enabled && !appActive && waiting.contains { !dropped.contains($0) }
    }

    /// Whether a notification that is no longer on screen is shown again: `reposts` is how many times it has been.
    static func repostDue(first: Date, reposts: Int, now: Date) -> Bool {
        reposts < repostAfter.count && now.timeIntervalSince(first) >= repostAfter[reposts]
    }

    // MARK: Alert style

    /// How macOS shows WorkTime's notifications: a banner leaves after a few seconds, an alert stays until it is dealt with.
    enum AlertStyle: Equatable, Sendable {
        case none, banner, alert
    }

    /// What to tell the user when decisions cannot stay on screen, nil when they can.
    static func styleWarning(_ style: AlertStyle, authorized: Bool) -> String? {
        guard authorized else { return "Notifications are off for WorkTime, so a question can only be answered in the notch bar." }
        switch style {
        case .alert: return nil
        case .banner: return "macOS shows WorkTime\u{2019}s notifications as Banners, which leave after a few seconds. Choose Alerts so they stay until you answer."
        case .none: return "macOS shows no notification for WorkTime on screen. Choose Alerts so a question stays until you answer."
        }
    }

    // MARK: Text

    /// A title or body for something the user will read: Slack's markup is turned into plain words.
    static func readable(_ text: String) -> String { SlackLogic.plain(text) }

    /// What a dismissed notification leaves in Resolved: where it led, when it led somewhere a reminder can point.
    static func resolvedSource(link: String?, jiraSite: String? = nil) -> ReminderSource? {
        guard let link else { return nil }
        switch NoticeLogic.link(link) {
        case .pullRequest(let target)?: return .pullRequest(target)
        case .jira(let key)?: return .jira(key: key)
        case .web(let url)?: return ReminderSource.parse(url.absoluteString, jiraSite: jiraSite)
        default: return nil
        }
    }
}
