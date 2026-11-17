import Foundation

/// One thing that happened in a session of a ticket or pull request, read from what the session already holds: its prompts, replies,
/// review and action blocks and the permissions the user answered. No store of its own.
struct TimelineEvent: Identifiable, Equatable {
    enum Kind: String, Equatable {
        /// What started the work: a Slack message, a review request, a ticket of mine.
        case trigger
        /// What Main asked the session to do.
        case prompt
        /// A verdict, PASS, FAIL or BLOCKED, or a recommendation.
        case outcome
        /// A drafted review.
        case review
        /// A review or comment that was posted, and by whom.
        case posted
        /// What the user wrote in the session.
        case feedback
        /// Calls the user allowed or refused.
        case approval
        /// A next step the session offered.
        case offer
        /// What the session reported to Main, or its last reply of a turn.
        case reply
    }

    let id: String
    /// The session's agent key and name, so the event can open it.
    let session: String
    let sessionLabel: String
    /// The item of the session's transcript to jump to; nil for an event that is not in it, like a review posted from a notification.
    let item: String?
    let date: Date
    let kind: Kind
    var title: String
    var detail: String?
    /// How many calls an approval stands for.
    var count = 1
}

/// Reading a session's items into events, a changed or new item at a time.
struct TimelineScanner: Equatable {
    static let titleLimit = 140
    static let detailLimit = 240

    let session: String
    let label: String
    private var signatures: [String: Int] = [:]
    private var found: [String: [TimelineEvent]] = [:]
    private(set) var order: [String] = []
    private var first: String?

    init(session: String, label: String) {
        self.session = session
        self.label = label
    }

    /// The events of every item, in the order of the items, with consecutive approvals folded into one.
    var events: [TimelineEvent] { Timeline.folded(order.flatMap { found[$0] ?? [] }) }

    /// Reads the items that are new or changed since the last call. A replaced transcript is read from the start. True when anything changed.
    @discardableResult
    mutating func update(_ items: [AgentItem]) -> Bool {
        var changed = false
        if first != items.first?.id || items.count < order.count {
            signatures = [:]
            found = [:]
            changed = !order.isEmpty
        }
        first = items.first?.id
        let ids = items.map(\.id)
        if ids != order {
            order = ids
            changed = true
            let known = Set(ids)
            for id in found.keys where !known.contains(id) { found[id] = nil; signatures[id] = nil }
        }
        for (index, item) in items.enumerated() where !item.streaming {
            let next = index + 1 < items.count ? items[index + 1] : nil
            let signature = Timeline.signature(item, next: next)
            guard signatures[item.id] != signature else { continue }
            signatures[item.id] = signature
            found[item.id] = Timeline.events(for: item, next: next, session: session, label: label)
            changed = true
        }
        return changed
    }
}

enum Timeline {
    /// The timeline of the group: every session's events together, oldest first.
    static func merged(_ lists: [[TimelineEvent]]) -> [TimelineEvent] {
        lists.flatMap { $0 }.enumerated().sorted { lhs, rhs in
            lhs.element.date == rhs.element.date ? lhs.offset < rhs.offset : lhs.element.date < rhs.element.date
        }.map(\.element)
    }

    /// Consecutive approvals of one session become one line.
    static func folded(_ events: [TimelineEvent]) -> [TimelineEvent] {
        var folded: [TimelineEvent] = []
        for event in events {
            if event.kind == .approval, var last = folded.last, last.kind == .approval, last.session == event.session {
                last.count += event.count
                last.detail = [last.detail, event.title].compactMap { $0 }.joined(separator: "\n").split(separator: "\n").suffix(4).joined(separator: "\n")
                last.title = approvalTitle(count: last.count)
                folded[folded.count - 1] = last
            } else {
                var event = event
                if event.kind == .approval { event.detail = event.title }
                if event.kind == .approval { event.title = approvalTitle(count: event.count) }
                folded.append(event)
            }
        }
        return folded
    }

    static func approvalTitle(count: Int) -> String { count == 1 ? "You answered a permission prompt" : "You answered \(count) permission prompts" }

    /// What changes when an item or the one after it changes.
    static func signature(_ item: AgentItem, next: AgentItem?) -> Int {
        var hasher = Hasher()
        hasher.combine(item.id)
        switch item.kind {
        case .user(let text), .text(let text), .error(let text), .status(let text): hasher.combine(text.utf8.count)
        case .tool(let name, _, _, let result, let isError, _, _): hasher.combine(name); hasher.combine(result?.utf8.count); hasher.combine(isError)
        case .permission(let tool, _, _, _, let allowed): hasher.combine(tool); hasher.combine(allowed)
        default: break
        }
        switch next?.kind {
        case nil: hasher.combine(0)
        case .user?: hasher.combine(1)
        default: hasher.combine(2)
        }
        return hasher.finalize()
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let one = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
        return one.count > limit ? String(one.prefix(limit - 1)) + "\u{2026}" : one
    }

    /// The first non-empty line, without Markdown marks.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "#> "))
    }

    /// PASS, FAIL or BLOCKED named in the headline of a reply, as a verifier ends one.
    static func verdict(in text: String) -> String? {
        let headline = firstLine(text)
        guard let match = headline.firstMatch(of: #/(?:^|[^A-Za-z])(PASS|FAIL|BLOCKED)(?![A-Za-z])/#) else { return nil }
        return String(match.1)
    }

    /// A triage's `Recommendation: review` line.
    static func recommendation(in text: String) -> String? {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.lowercased().hasPrefix("recommendation:") }
            .map { clip($0, TimelineScanner.titleLimit) }
    }

    static func events(for item: AgentItem, next: AgentItem?, session: String, label: String) -> [TimelineEvent] {
        func event(_ suffix: String, _ kind: TimelineEvent.Kind, _ title: String, detail: String? = nil) -> TimelineEvent {
            TimelineEvent(id: "\(session)|\(item.id)|\(suffix)", session: session, sessionLabel: label, item: item.id, date: item.date, kind: kind,
                          title: clip(title, TimelineScanner.titleLimit), detail: detail.map { clip($0, TimelineScanner.detailLimit) })
        }
        switch item.kind {
        case .user(let text):
            if let message = AgentInbox.fromMain(text) {
                var events: [TimelineEvent] = []
                if let origin = AgentInbox.origin(of: text) { events.append(event("trigger", .trigger, "Triggered by \(origin)")) }
                events.append(event("prompt", .prompt, "Main asked: " + firstLine(message), detail: message))
                return events
            }
            if let report = AgentReports.parse(text) { return [event("report", .reply, "Report from \(report.from): " + firstLine(report.text), detail: report.text)] }
            return [event("feedback", .feedback, "You: " + firstLine(text), detail: text)]
        case .text(let text):
            var events: [TimelineEvent] = []
            var index = 0
            for segment in AgentActions.segments(text) {
                switch segment {
                case .review(let draft):
                    events.append(event("review-\(index)", .review, "Review draft \u{00B7} \(draft.reference) \u{00B7} \(draft.verdict.title)", detail: draft.summary))
                case .action(let action):
                    events.append(event("offer-\(index)", .offer, "Offered: " + action.title, detail: action.prompt))
                case .markdown: break
                }
                index += 1
            }
            if let word = verdict(in: text) {
                events.append(event("verdict", .outcome, "\(word): " + firstLine(text), detail: text))
            } else if let advice = recommendation(in: text) {
                events.append(event("recommendation", .outcome, advice))
            }
            let endsTurn: Bool = { if case .user? = next?.kind { true } else { next == nil } }()
            if events.isEmpty, endsTurn, !firstLine(text).isEmpty { events.append(event("reply", .reply, "Replied: " + firstLine(text), detail: text)) }
            return events
        case .permission(let tool, let summary, _, _, let allowed):
            guard let allowed else { return [] }
            return [TimelineEvent(id: "\(session)|\(item.id)|approval", session: session, sessionLabel: label, item: item.id, date: item.date, kind: .approval,
                                  title: "\(allowed ? "Allowed" : "Refused"): \(AgentLogic.displayName(tool))" + (summary.isEmpty ? "" : " \u{2014} " + clip(summary, 80)))]
        case .tool(let name, let summary, let detail, let result, let isError, _, _):
            guard result != nil, !isError else { return [] }
            if name == "Bash", let call = reviewCall(summary + "\n" + detail) {
                return [event("posted", .posted, "Review posted on \(call)", detail: summary)]
            }
            if name == AgentReports.tool || name.hasSuffix("__send_to_main") {
                return [event("report", .reply, "Reported to Main: " + firstLine(summary.isEmpty ? detail : summary), detail: detail)]
            }
            return []
        default:
            return []
        }
    }

    /// The pull request a `gh pr review` or review API call was made on, as `repo#12`.
    static func reviewCall(_ command: String) -> String? {
        let text = command.lowercased()
        guard text.contains("gh pr review") || (text.contains("gh api") && text.contains("/reviews")) else { return nil }
        if let target = GitHubLink.mentions(in: command).first { return "\(target.repo)#\(target.number)" }
        if let match = command.firstMatch(of: #/repos/([^/\s]+/[^/\s]+)/pulls/([0-9]+)/#) { return "\(match.1)#\(match.2)" }
        return "the pull request"
    }

    // MARK: Posted actions

    /// The reviews and comments the user posted from a notification, the notch or a card, from the app's log of GitHub actions.
    static func posted(_ records: [GitHubActionRecord], url: (GitHubActionRecord) -> String?, session: (String) -> (key: String, label: String)?) -> [TimelineEvent] {
        records.compactMap { record in
            guard record.succeeded, [.approve, .requestChanges, .comment].contains(record.action), let address = url(record), let owner = session(address) else { return nil }
            var how = [record.actor.map { "by \($0)" }, record.via.map { "from \($0)" }, record.sha.map { "at \(ReviewApproval.short($0))" }].compactMap { $0 }
            if how.isEmpty { how = ["posted"] }
            return TimelineEvent(id: "log|\(record.id)", session: owner.key, sessionLabel: owner.label, item: nil, date: record.at, kind: .posted,
                                 title: "\(record.action.title) on \(record.repo)#\(record.number) " + how.joined(separator: " "), detail: record.title)
        }
    }
}
