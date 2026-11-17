import Foundation

/// A write left in the inbox without waiting for the app's answer: what the `--mcp` process remembers about it so `request_status` can say how it went.
struct AsyncRequest: Codable, Equatable {
    var id: String
    var created: Date
    /// What the prompt is for, as the answer to the caller names it.
    var target: String
    var ticket: String?
    var pullRequest: String?
    var role: String?
    /// The call can wait on the user (a reuse-or-new question), up to `deadline`.
    var waitsForUser: Bool
    var deadline: Date
}

enum RequestState: String, Codable, CaseIterable {
    case pending, answered, created, started
    case timedOut = "timed_out"
    case refused
}

struct RequestStatus: Equatable {
    var id: String
    var state: RequestState
    var message: String
    var sessionID: String?
    var ticket: String?
    var pullRequest: String?
    var role: String?
    var note: String?
    var waitingForUser = false
    var sessionKey: String?

    var isFinal: Bool { state != .pending && state != .answered }
}

enum RequestStatuses {
    static let suffix = ".async.json"
    static let takeBy: TimeInterval = 60
    static let answeredAfter: TimeInterval = 3

    static func recordName(_ id: String) -> String { id + suffix }

    static func isRecord(_ name: String) -> Bool { name.hasSuffix(suffix) }

    static func record(for request: AgentInbox.Request, target: String, role: String?, waitsForUser: Bool, waitSeconds: Int, now: Date) -> AsyncRequest {
        AsyncRequest(id: request.id, created: now, target: target, ticket: request.ticket, pullRequest: request.pr ?? request.prs?.first, role: role,
                     waitsForUser: waitsForUser, deadline: now.addingTimeInterval(waitsForUser ? TimeInterval(waitSeconds) + takeBy : takeBy))
    }

    /// How a request stands: what the app replied, else whether the app has taken it, the user has a question about it, or the time is up.
    static func status(_ record: AsyncRequest, reply: AgentInbox.Reply?, inInbox: Bool, decisions: [PendingDecision], agents: [AgentState], now: Date) -> RequestStatus {
        var status = RequestStatus(id: record.id, state: .pending, message: "", ticket: record.ticket, pullRequest: record.pullRequest, role: record.role)
        if let reply {
            status.sessionID = reply.sessionID
            status.note = reply.note
            switch reply.status {
            case .rejected:
                status.state = reply.timedOut == true ? .timedOut : .refused
                status.message = reply.message
            case .started, .queued:
                status.state = reply.created == true ? .created : .started
                status.message = reply.created == true ? "A new session was made and the prompt " + (reply.status == .queued ? "is queued." : "started.")
                    : reply.status == .queued ? "The prompt is queued in the session; it starts when the agent finishes its current prompt." : "The prompt started in the session."
            }
            if let session = reply.sessionID, let state = agents.first(where: { $0.sessionID == session }) {
                status.sessionKey = state.key
                status.ticket = status.ticket ?? state.jiraKey
                status.role = status.role ?? state.role
            }
            return status
        }
        if decisions.contains(where: { $0.id == "ask:" + record.id }) {
            status.waitingForUser = true
            status.message = "Waiting for the user to choose between reusing the session and starting a new one."
            return status
        }
        if now >= record.deadline {
            status.state = .timedOut
            status.message = inInbox ? "WorkTime did not take the prompt. Is the app running?" : "The user did not answer in time; nothing was sent."
            return status
        }
        if inInbox {
            status.message = "WorkTime has not picked the prompt up yet."
        } else if record.waitsForUser, now.timeIntervalSince(record.created) >= answeredAfter {
            status.state = .answered
            status.message = "The question is no longer waiting; the prompt is being delivered."
        } else {
            status.message = "WorkTime is handling the prompt."
        }
        return status
    }

    static func markdown(_ status: RequestStatus) -> String {
        var lines = ["request_id: \(status.id)", "state: \(status.state.rawValue)", status.message]
        if let note = status.note, !note.isEmpty { lines.append(note) }
        if let session = status.sessionID { lines.append("session_id: \(session)" + (status.sessionKey.map { " (agent \($0))" } ?? "")) }
        if let ticket = status.ticket { lines.append("ticket: \(ticket)") }
        if let pr = status.pullRequest { lines.append("pull request: \(pr)") }
        if let role = status.role { lines.append("role: \(role)") }
        if status.waitingForUser { lines.append("It waits for the user; only they can answer it, in the app (see pending_decisions).") }
        lines.append(status.isFinal ? "This is final." : "Check again with request_status, or block on it with wait_for.")
        return lines.joined(separator: "\n") + "\n"
    }
}

enum WaitUntil: String, CaseIterable {
    case idle, finished, needsYou = "needs_you", any
}

/// What `wait_for` watches: a session by its id, a ticket's agents, or the session a request made.
struct WaitTarget: Equatable {
    var session: String?
    var ticket: String?
    var request: AsyncRequest?
}

struct WaitSnapshot {
    var agents: [AgentState]
    var decisions: [PendingDecision]
    var request: RequestStatus?
}

struct WaitResult: Equatable {
    var reason: String
    var members: [AgentState]
    var decisions: [PendingDecision]
    var request: RequestStatus?
    var waited: TimeInterval
}

enum WaitFor {
    static let maximum: TimeInterval = 600
    static let fallback: TimeInterval = 120
    static let interval: TimeInterval = 0.5

    static func timeout(_ value: Any?) -> TimeInterval {
        min(max(MCPServer.number(value) ?? fallback, 1), maximum)
    }

    static func members(_ target: WaitTarget, in snapshot: WaitSnapshot) -> [AgentState] {
        let live = snapshot.agents.filter { $0.archived != true }
        if let session = target.session ?? snapshot.request?.sessionID { return live.filter { $0.sessionID == session } }
        if let ticket = target.ticket { return live.filter { AgentFilter.about($0, ticket: ticket) && !Workspaces.isMainKey($0.key) } }
        return []
    }

    private static func fingerprint(_ members: [AgentState]) -> [String] {
        members.map { "\($0.key)|\($0.status.rawValue)|\($0.lastResult?.hashValue ?? 0)|\($0.updatedAt?.timeIntervalSince1970 ?? 0)" }.sorted()
    }

    /// Whether the condition holds for the members now; nil when it does not yet. `started` is when the request was made, so a state file
    /// written before the agent began is not taken for the agent's end.
    static func check(_ until: WaitUntil, members: [AgentState], decisions: [PendingDecision], initial: [String], since: Date?) -> String? {
        if members.isEmpty { return nil }
        let waiting = members.contains { [.waiting, .error, .signedOut].contains($0.status) }
            || members.contains { !PendingDecisions.waiting(on: $0, in: decisions).isEmpty }
        if waiting { return "needs_you" }
        if until == .needsYou { return nil }
        let working = members.contains { $0.status == .working }
        if until == .any { return fingerprint(members) != initial ? "changed" : nil }
        if working { return nil }
        if let since, !members.contains(where: { ($0.updatedAt ?? .distantPast) >= since }) { return nil }
        if until == .finished { return members.contains { $0.lastResult != nil } ? "finished" : nil }
        return "idle"
    }

    /// Watches until the condition holds or `timeout` seconds pass; `sleep` and `now` are the caller's, so a test needs no real time.
    static func run(_ target: WaitTarget, until: WaitUntil, timeout: TimeInterval, read: () -> WaitSnapshot, sleep: (TimeInterval) -> Void,
                    now: () -> Date) -> WaitResult {
        let start = now()
        var snapshot = read()
        var initial: [String]?
        while true {
            let members = members(target, in: snapshot)
            let waited = now().timeIntervalSince(start)
            func result(_ reason: String) -> WaitResult {
                WaitResult(reason: reason, members: members, decisions: members.flatMap { PendingDecisions.waiting(on: $0, in: snapshot.decisions) },
                           request: snapshot.request, waited: waited)
            }
            if let request = snapshot.request {
                if request.state == .refused || request.state == .timedOut { return result(request.state.rawValue) }
                if request.waitingForUser { return result("needs_you") }
            }
            if initial == nil { initial = fingerprint(members) }
            if let reason = check(until, members: members, decisions: snapshot.decisions, initial: initial ?? [], since: target.request?.created) {
                return result(reason)
            }
            if waited >= timeout { return result("timed_out") }
            sleep(min(interval, max(timeout - waited, 0.01)))
            snapshot = read()
        }
    }

    static func markdown(_ result: WaitResult, now: Date) -> String {
        var lines = ["result: \(result.reason)", "waited: \(Int(result.waited.rounded())) s"]
        if let request = result.request { lines.append("request: \(request.state.rawValue)" + (request.message.isEmpty ? "" : " \u{2014} \(request.message)")) }
        if result.members.isEmpty { lines.append("No agent matched yet.") }
        for state in result.members {
            lines.append(AgentOverview.line(state, now: now).trimmingCharacters(in: .newlines))
        }
        if result.reason == "finished" || result.reason == "idle" {
            for state in result.members {
                if let last = state.lastResult { lines.append("\nLast result of \(state.title):\n\(last)") }
            }
        }
        for decision in result.decisions { lines.append("waiting on the user: \(decision.kind.rawValue) \u{2014} \(decision.title) \u{00B7} \(decision.link ?? decision.id)") }
        return lines.joined(separator: "\n") + "\n"
    }
}
