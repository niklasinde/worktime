import Foundation

/// Something that happened in the app that a coordinating Claude Code session may want to react to.
struct AppEvent: Codable, Equatable {
    var id: Int
    var date: Date
    var kind: String
    var text: String
    var session: String?
    var ticket: String?
    var link: String?
}

/// The feed `events_since` reads: a small capped file of events with ids that only ever grow, so a cursor stays valid across restarts.
enum AppEvents {
    static let fileName = "events.json"
    static let limit = 200
    static let latestCount = 20
    static let pageLimit = 100

    enum Kind: String, CaseIterable {
        case sessionStarted = "session_started", sessionFinished = "session_finished", sessionErrored = "session_errored"
        case sessionWaiting = "session_waiting", decisionRaised = "decision_raised", decisionAnswered = "decision_answered"
        case reviewPosted = "review_posted", automationFired = "automation_fired", routineRan = "routine_ran", appRestarted = "app_restarted"
    }

    struct Draft: Equatable {
        var kind: Kind
        var text: String
        var session: String?
        var ticket: String?
        var link: String?
    }

    struct File: Codable, Equatable {
        var events: [AppEvent] = []
    }

    static func decode(_ data: Data?) -> File { data.flatMap { AgentInbox.decode(File.self, from: $0) } ?? File() }

    static func encode(_ file: File) -> Data { AgentInbox.encode(file) }

    /// The file with the drafts added under the next ids, the oldest dropped past the limit. The first id is the time in seconds, so a deleted
    /// file does not hand out ids a client has already seen.
    static func appending(_ drafts: [Draft], to file: File, now: Date) -> File {
        var file = file
        var next = (file.events.last?.id ?? Int(now.timeIntervalSince1970)) + 1
        for draft in drafts {
            file.events.append(AppEvent(id: next, date: now, kind: draft.kind.rawValue, text: draft.text, session: draft.session, ticket: draft.ticket, link: draft.link))
            next += 1
        }
        if file.events.count > limit { file.events.removeFirst(file.events.count - limit) }
        return file
    }

    /// Without a cursor the newest id and the last events; with one, the events after it, oldest first, and the cursor to pass next time.
    static func since(_ cursor: Int?, limit count: Int, in file: File) -> (events: [AppEvent], cursor: Int) {
        let newest = file.events.last?.id ?? cursor ?? 0
        guard let cursor else { return (Array(file.events.suffix(latestCount)), newest) }
        let size = min(max(count, 1), pageLimit)
        let found = Array(file.events.filter { $0.id > cursor }.prefix(size))
        return (found, found.last?.id ?? max(cursor, 0))
    }

    static func markdown(_ events: [AppEvent], cursor: Int, first: Bool, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["cursor: \(cursor)" + (first ? " (newest; pass it as cursor to get what happens next)" : "")]
        if events.isEmpty { lines.append(first ? "No events yet." : "Nothing new.") }
        for event in events {
            var parts = ["#\(event.id)", formatter.string(from: event.date), event.kind, event.text]
            if let ticket = event.ticket { parts.append(ticket) }
            if let session = event.session { parts.append("session \(session)") }
            if let link = event.link { parts.append(link) }
            lines.append("- " + parts.joined(separator: " \u{00B7} "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Deriving events

    /// What the move from one snapshot of the agents to the next means: a session that began working, finished, stopped with an error or started
    /// waiting for a permission. The first snapshot after a start has nothing to compare with and gives none.
    static func sessionEvents(old: [AgentState], new: [AgentState]) -> [Draft] {
        let before = Dictionary(old.map { ($0.key, $0) }) { first, _ in first }
        var drafts: [Draft] = []
        for state in new where state.archived != true {
            guard let previous = before[state.key], previous.status != state.status else { continue }
            func draft(_ kind: Kind, _ text: String) -> Draft {
                Draft(kind: kind, text: "\(state.title): \(text)", session: state.sessionID, ticket: state.jiraKey ?? ticket(in: state.title), link: link(state))
            }
            switch (previous.status, state.status) {
            case (_, .working): drafts.append(draft(.sessionStarted, "started working"))
            case (.working, .idle), (.waiting, .idle):
                drafts.append(draft(.sessionFinished, state.lastResult.map { Timeline.clip($0, 160) } ?? "finished"))
            case (_, .waiting): drafts.append(draft(.sessionWaiting, "waits for permission" + (state.pendingTool.map { " to run \(AgentLogic.displayName($0))" } ?? "")))
            case (_, .error), (_, .signedOut): drafts.append(draft(.sessionErrored, state.error.map { Timeline.clip($0, 160) } ?? "stopped with an error"))
            default: break
            }
        }
        return drafts
    }

    /// Decisions that appeared or went away between two snapshots.
    static func decisionEvents(old: [PendingDecision], new: [PendingDecision]) -> [Draft] {
        let before = Set(old.map(\.id)), now = Set(new.map(\.id))
        let raised = new.filter { !before.contains($0.id) }.map {
            Draft(kind: .decisionRaised, text: "\($0.kind): \($0.title)", session: $0.session, ticket: $0.ticket, link: $0.link)
        }
        let answered = old.filter { !now.contains($0.id) }.map {
            Draft(kind: .decisionAnswered, text: "\($0.kind): \($0.title)", session: $0.session, ticket: $0.ticket, link: $0.link)
        }
        return raised + answered
    }

    /// Reviews posted that were not there in the earlier snapshot of the timelines.
    static func postedEvents(known: Set<String>, groups: [TimelineGroup]) -> [Draft] {
        groups.flatMap { group in
            group.events.filter { $0.kind == TimelineEvent.Kind.posted.rawValue && !known.contains($0.id) }.map {
                Draft(kind: .reviewPosted, text: $0.title, session: nil, ticket: group.ticket, link: group.pullRequest)
            }
        }
    }

    static func postedIDs(_ groups: [TimelineGroup]) -> Set<String> {
        Set(groups.flatMap { $0.events.filter { $0.kind == TimelineEvent.Kind.posted.rawValue }.map(\.id) })
    }

    private static func ticket(in title: String) -> String? { title.firstMatch(of: #/\b([A-Z][A-Z0-9]+-[0-9]+)\b/#).map { String($0.1) } }

    private static func link(_ state: AgentState) -> String {
        state.prURL.map(GitHubLink.agentLink) ?? OpenLinks.link(.agent(state.key))
    }
}
