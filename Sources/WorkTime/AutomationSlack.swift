import Foundation

/// The Slack events beyond mentions and direct messages: the new messages of chosen channels, messages with a keyword and replies in
/// threads the user wrote in, all found with Slack's search.
extension Automations {
    static let slackQueryLimit = 6
    static let slackThreadLimit = 8
    static let slackCount = 20

    /// The searches one automation needs, narrowed to the last day so a restart reads little.
    static func slackQueries(_ trigger: AutomationTrigger, now: Date, calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let after = "after:" + formatter.string(from: now.addingTimeInterval(-86_400))
        let places = words(trigger.place).map { word in word.hasPrefix("@") ? "from:\(word)" : "in:#" + word.drop { $0 == "#" } }
        let texts = words(trigger.text)
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "") + "\"" }
        let queries: [String]
        switch trigger.kind {
        case .slackChannel: queries = places.map { [$0, texts.count == 1 ? quoted(texts[0]) : nil, after].compactMap { $0 }.joined(separator: " ") }
        case .slackKeyword: queries = texts.flatMap { text in (places.isEmpty ? [""] : places).map { [quoted(text), $0, after].filter { !$0.isEmpty }.joined(separator: " ") } }
        case .slackReply: queries = ["is:thread from:me \(after)"]
        default: queries = []
        }
        return Array(queries.prefix(slackQueryLimit))
    }

    /// The events of a search's messages: the ones the user wrote themselves are not.
    static func slackSearchEvents(_ messages: [SlackMessage], kind: AutomationTrigger.Kind, me: SlackIdentity, workspace: String?) -> [AutomationEvent] {
        messages.filter { $0.author != me.user && $0.author != me.userID }
            .map { slackEvent($0, link: SlackLogic.webLink($0, workspace: workspace), kind: kind) }
    }

    /// The thread links of the user's own messages in threads, newest first, one per thread.
    static func slackThreads(_ messages: [SlackMessage]) -> [(root: SlackMessage, link: SlackThreadLink)] {
        var seen = Set<String>()
        return messages.compactMap { message in
            guard let link = message.permalink.flatMap(SlackLogic.threadLink), seen.insert(link.channel + link.root).inserted else { return nil }
            return (message, link)
        }.prefix(slackThreadLimit).map { $0 }
    }

    /// The replies other people wrote in a thread, newer than the window; the first message is the thread's own.
    static func slackReplyEvents(_ thread: [SlackRawMessage], root: SlackMessage, link: SlackThreadLink, names: [String: String], me: SlackIdentity,
                                 workspace: String?, now: Date) -> [AutomationEvent] {
        thread.filter { $0.ts != link.root && $0.user != me.userID }.compactMap { raw in
            let message = SlackMessage(kind: .mention, teamID: root.teamID, channelID: root.channelID, place: root.place,
                                       author: raw.user.map { names[$0] ?? $0 }, text: raw.text, ts: raw.ts, permalink: nil, unread: nil, threadTS: link.root)
            guard message.date >= now.addingTimeInterval(-recentWindow) else { return nil }
            return slackEvent(message, link: SlackLogic.webLink(message, workspace: workspace), kind: .slackReply)
        }
    }
}
