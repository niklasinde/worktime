import Foundation

/// Slack messages pushed over the socket as automation events. They get the same ids as the ones Slack's search finds, so a message
/// both ways starts a run once.
extension Automations {
    /// The Slack triggers the socket can serve.
    static let pushedKinds: Set<AutomationTrigger.Kind> = [.slackChannel, .slackKeyword, .slackReply, .slackMessage]

    /// The Slack kinds the automations that are on wait for; none means the socket is not needed.
    static func pushedKinds(of routines: [Routine]) -> Set<AutomationTrigger.Kind> {
        Set(routines.filter(\.enabled).compactMap { $0.trigger?.kind }.filter(pushedKinds.contains))
    }

    /// Where the message was written: `#channel`, the person for a direct message, the people for a group message.
    static func socketPlace(_ event: SlackSocketEvent, conversation name: String?, author: String?) -> String {
        switch event.channelType {
        case "im": return author ?? "Direct message"
        case "mpim": return name.map(SlackLogic.groupName).flatMap { $0.isEmpty ? nil : $0 } ?? "Group message"
        default: return "#" + (name ?? event.channel)
        }
    }

    /// Whether a pushed message can start anything, so the ones that cannot cost no lookup: with only replies wanted, a message that
    /// is no reply is of no use.
    static func socketUseful(_ event: SlackSocketEvent, kinds: Set<AutomationTrigger.Kind>) -> Bool {
        !kinds.isEmpty && (event.isReply || !kinds.isSubset(of: [.slackReply]))
    }

    static func socketMessage(_ event: SlackSocketEvent, place: String, author: String?, me: SlackIdentity) -> SlackMessage {
        SlackMessage(kind: event.isDirect ? .direct : .mention, teamID: me.teamID, channelID: event.channel, place: place, author: author,
                     text: event.text, ts: event.ts, permalink: nil, unread: nil, threadTS: event.isReply ? event.threadTS : nil)
    }

    /// The events a pushed message makes for the `kinds` that are wanted. A reply counts only in a thread the user wrote in, a
    /// mention or direct message only when it is one.
    static func socketEvents(_ message: SlackMessage, event: SlackSocketEvent, kinds: Set<AutomationTrigger.Kind>, me: SlackIdentity,
                             inMyThread: Bool) -> [(kind: AutomationTrigger.Kind, event: AutomationEvent)] {
        let link = SlackLogic.webLink(message, workspace: me.url)
        let mentioned = event.text.contains("<@\(me.userID)>")
        return kinds.sorted { $0.rawValue < $1.rawValue }.compactMap { kind in
            switch kind {
            case .slackChannel, .slackKeyword: break
            case .slackReply: guard event.isReply, inMyThread else { return nil }
            case .slackMessage: guard event.isDirect || mentioned else { return nil }
            default: return nil
            }
            return (kind, slackEvent(message, link: link, kind: kind))
        }
    }

    /// The automations of `kind` a pushed event goes to: the ones that have already looked at what was there, as an event is new only
    /// after that; and whether one has not, so a search has to do it first.
    static func socketTargets(kind: AutomationTrigger.Kind, routines: [Routine], baselined: Set<String>) -> (hand: [String], needsBaseline: Bool) {
        let wanted = routines.filter { $0.enabled && $0.trigger?.kind == kind }
        return (wanted.filter { baselined.contains($0.id) }.map(\.id), wanted.contains { !baselined.contains($0.id) })
    }
}
