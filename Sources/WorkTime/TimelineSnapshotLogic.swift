import Foundation

/// An event of a ticket's or pull request's timeline, as `ticket_timeline` lists it.
struct TimelineEntry: Codable, Equatable {
    var id: String
    var date: Date
    var kind: String
    var title: String
    var detail: String?
    var session: String
    var sessionLabel: String
}

/// The latest verdict or recommendation of a group: PASS, FAIL, BLOCKED or Recommendation.
struct TimelineOutcome: Codable, Equatable {
    var verdict: String
    var text: String
    var date: Date
    var sessionLabel: String
}

/// One ticket or pull request with its sessions' timeline, written by the app so the `--mcp` process does not read transcripts.
struct TimelineGroup: Codable, Equatable {
    var key: String
    var label: String
    var ticket: String?
    var pullRequest: String?
    var pullRequests: [String] = []
    var title: String?
    var spaces: [String] = []
    var sessions: [String] = []
    var updated: Date?
    var outcome: TimelineOutcome?
    var events: [TimelineEntry]
}

enum TimelineSnapshots {
    static let fileName = "timeline.json"
    static let groupLimit = 60
    static let eventLimit = 80
    static let verdicts = ["PASS", "FAIL", "BLOCKED"]

    struct File: Codable, Equatable {
        var written: Date
        var groups: [TimelineGroup]
    }

    static func encode(_ groups: [TimelineGroup], now: Date) -> Data { AgentInbox.encode(File(written: now, groups: groups)) }

    static func decode(_ data: Data?) -> File? { data.flatMap { AgentInbox.decode(File.self, from: $0) } }

    /// The group as a snapshot: its newest `eventLimit` events (oldest first) and the latest outcome among all of them.
    static func group(_ group: TicketGroup, events: [TimelineEvent], title: String? = nil) -> TimelineGroup {
        let entries = events.map {
            TimelineEntry(id: $0.id, date: $0.date, kind: $0.kind.rawValue, title: $0.title, detail: $0.detail, session: $0.session, sessionLabel: $0.sessionLabel)
        }
        let live = group.members
        return TimelineGroup(key: group.id, label: group.subject.label, ticket: group.ticket, pullRequest: group.subject.pullRequest,
                             pullRequests: group.chips.map(\.url), title: title, spaces: Array(Set(live.flatMap { $0.spaces ?? [] })).sorted(),
                             sessions: live.compactMap(\.sessionID), updated: group.latest ?? entries.last?.date, outcome: outcome(in: entries),
                             events: Array(entries.suffix(eventLimit)))
    }

    /// The newest event that is a verdict or a recommendation.
    static func outcome(in entries: [TimelineEntry]) -> TimelineOutcome? {
        guard let entry = entries.last(where: { $0.kind == TimelineEvent.Kind.outcome.rawValue }) else { return nil }
        let head = entry.title.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let verdict = verdicts.contains(head) ? head : "Recommendation"
        return TimelineOutcome(verdict: verdict, text: entry.detail.map { Timeline.firstLine($0) } ?? entry.title, date: entry.date, sessionLabel: entry.sessionLabel)
    }

    /// The groups most recently touched, newest first, up to the cap.
    static func capped(_ groups: [TimelineGroup]) -> [TimelineGroup] {
        Array(groups.sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }.prefix(groupLimit))
    }

    // MARK: Reading

    /// The group for a ticket key or a pull request address; a pull request that belongs to a ticket's group finds that group.
    static func find(ticket: String?, pullRequest: String?, in groups: [TimelineGroup]) -> TimelineGroup? {
        if let ticket { return groups.first { $0.ticket?.caseInsensitiveCompare(ticket) == .orderedSame } }
        guard let pullRequest else { return nil }
        return groups.first { $0.pullRequest == pullRequest } ?? groups.first { $0.pullRequests.contains(pullRequest) }
    }

    static func markdown(_ group: TimelineGroup, now: Date, timeZone: TimeZone = .current, limit: Int = eventLimit) -> String {
        var lines = ["## \(group.label)" + (group.title.map { " \u{00B7} \($0)" } ?? "")]
        if let outcome = group.outcome { lines.append("Latest outcome: **\(outcome.verdict)** \u{00B7} \(outcome.text) (\(outcome.sessionLabel), \(ClaudePlugin.ago(outcome.date, now: now)))") }
        if !group.pullRequests.isEmpty { lines.append("Pull requests: " + group.pullRequests.joined(separator: ", ")) }
        lines.append("")
        let events = group.events.suffix(limit)
        if events.isEmpty { lines.append("No events yet.") }
        for event in events {
            lines.append("- \(stamp(event.date, timeZone)) \u{00B7} \(event.kind) \u{00B7} \(event.title) (\(event.sessionLabel))")
            if let detail = event.detail, !detail.isEmpty, detail != event.title { lines.append("  \(detail)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A compact table of each group's latest outcome, newest first, with the filters applied.
    static func outcomes(_ groups: [TimelineGroup], ticket: String? = nil, space: String? = nil, since: Date? = nil, now: Date) -> String {
        let shown = groups.filter { group in
            (ticket.map { group.ticket?.caseInsensitiveCompare($0) == .orderedSame } ?? true)
                && (space.map { group.spaces.contains($0) } ?? true)
                && (since.map { (group.outcome?.date ?? .distantPast) >= $0 } ?? true)
        }.sorted { ($0.outcome?.date ?? .distantPast) > ($1.outcome?.date ?? .distantPast) }
        guard !shown.isEmpty else { return "No outcomes match.\n" }
        var lines = ["| Subject | Outcome | Detail | By | When |", "| --- | --- | --- | --- | --- |"]
        for group in shown {
            guard let outcome = group.outcome else {
                lines.append("| \(cell(group.label)) | none yet | | | |")
                continue
            }
            lines.append("| \(cell(group.label)) | \(outcome.verdict) | \(cell(Timeline.clip(outcome.text, 100))) | \(cell(outcome.sessionLabel)) | \(ClaudePlugin.ago(outcome.date, now: now)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "/") }

    private static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
