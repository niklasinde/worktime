import Foundation
import OSLog

enum AgentDiagnostics {
    private static let log = Logger(subsystem: "com.niklasinde.MeetingRecorder", category: "agent-diagnostics")

    static func record(_ stage: String, run: String? = nil, session: String? = nil, turn: String? = nil, request: String? = nil) {
        func id(_ value: String?) -> String { value.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() ?? "-" }
        log.notice("\(stage, privacy: .public) run=\(id(run), privacy: .public) session=\(id(session), privacy: .public) turn=\(id(turn), privacy: .public) request=\(id(request), privacy: .public)")
    }
}

/// A message an agent sends into its workspace's Main: written by the `--mcp` process into the agent inbox and answered with a reply file.
struct ReportRequest: Codable, Equatable {
    var id: String
    /// The workspace id or name the caller named; empty for the caller's own.
    var workspace: String?
    var title: String?
    var text: String
    var source: NoticeSource
    var created: Date
}

/// What the app decides about a report before it reaches Main's chat.
enum ReportDecision: Equatable {
    case deliver(workspace: String, name: String, prompt: String)
    case duplicate
    case reject(String)
}

/// Reports to Main: who they come from, which Main they reach, and how often one agent may send them.
enum AgentReports {
    static let requestSuffix = ".report.json"
    static let prefix = "Report from "
    static let textLimit = AgentInbox.textLimit
    static let titleLimit = 80
    static let hourlyLimit = 6
    static let pendingLimit = 2
    static let dedupeWindow: TimeInterval = 600
    static let staleAfter: TimeInterval = 60
    static let routineSuffix = " (routine)"
    static let tool = "mcp__worktime__send_to_main"

    static func requestName(_ id: String) -> String { id + requestSuffix }
    static func isRequest(_ name: String) -> Bool { name.hasSuffix(requestSuffix) }

    // MARK: Prompts

    /// What Main receives: the sender's name and the text, in one line before it so the chat can show who it is from.
    static func prompt(from name: String, title: String?, text: String) -> String {
        let heading = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return prefix + name + ": " + (heading.map { $0 + "\n" } ?? "") + text
    }

    /// The sender and the text of a prompt that is a report, or nil for one the user wrote or Main sent.
    static func parse(_ prompt: String) -> (from: String, text: String)? {
        guard prompt.hasPrefix(prefix) else { return nil }
        let rest = prompt.dropFirst(prefix.count)
        guard let end = rest.range(of: ": "), !rest[..<end.lowerBound].contains(where: \.isNewline) else { return nil }
        return (String(rest[..<end.lowerBound]), String(rest[end.upperBound...]))
    }

    // MARK: Who and where

    /// The name a report carries: the agent's title, with a routine marked, else what its key or folder says.
    static func name(of source: NoticeSource, titles: [String: String]) -> String {
        let label = source.label(titles: titles)
        guard let agent = source.agent, Routines.isKey(agent) else { return label }
        return label + routineSuffix
    }

    /// The workspace whose Main receives the report: the one named by id or name, else the caller's own.
    static func target(argument: String?, caller: String?, in workspaces: [Workspace]) -> Result<Workspace, AgentInboxError> {
        let named = argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !named.isEmpty {
            guard named != Workspaces.allChoice else { return .failure(AgentInboxError("Name one workspace, not all.")) }
            if let found = workspaces.first(where: { $0.id.lowercased() == named }) ?? workspaces.first(where: { $0.name.lowercased() == named }) {
                return .success(found)
            }
            return .failure(AgentInboxError("No workspace \(argument ?? ""). Known: \(workspaces.map(\.id).joined(separator: ", "))."))
        }
        guard let caller = caller, !caller.isEmpty else {
            return .failure(AgentInboxError("workspace is required outside a WorkTime agent. Known: \(workspaces.map(\.id).joined(separator: ", "))."))
        }
        guard let own = workspaces.first(where: { $0.id == caller }) else {
            return .failure(AgentInboxError("The caller's workspace \(caller) is not one WorkTime knows."))
        }
        return .success(own)
    }

    /// Whether the caller is the Main that would receive the report.
    static func isSelf(_ source: NoticeSource, workspace: String) -> Bool {
        source.agent.flatMap(Workspaces.id(ofMainKey:)) == workspace
    }

    // MARK: Limits

    struct Sent: Equatable {
        var caller: String
        var digest: String
        var date: Date
    }

    /// The reports delivered recently, so one agent cannot flood Main or bounce the same text again and again.
    struct Ledger: Equatable {
        var sent: [Sent] = []

        mutating func prune(now: Date) { sent.removeAll { now.timeIntervalSince($0.date) > 3600 } }

        mutating func record(caller: String, text: String, now: Date) {
            prune(now: now)
            sent.append(Sent(caller: caller, digest: digest(text), date: now))
        }

        /// Why one more report from `caller` is not delivered, or nil when it is. `pending` counts its reports still waiting in Main's queue.
        func problem(caller: String, text: String, pending: Int, now: Date) -> Problem? {
            let mine = sent.filter { $0.caller == caller && now.timeIntervalSince($0.date) <= 3600 }
            let digest = AgentReports.digest(text)
            if mine.contains(where: { $0.digest == digest && now.timeIntervalSince($0.date) <= AgentReports.dedupeWindow }) { return .duplicate }
            if pending >= AgentReports.pendingLimit {
                return .refused("\(pending) of your reports are still waiting in Main's queue; wait until Main has read them.")
            }
            if mine.count >= AgentReports.hourlyLimit {
                return .refused("You have sent \(mine.count) reports in the last hour; the limit is \(AgentReports.hourlyLimit). Put what is left in your final answer.")
            }
            return nil
        }
    }

    enum Problem: Equatable {
        case duplicate
        case refused(String)
    }

    static func digest(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How many of `queued` prompts in Main's queue are reports from `name`.
    static func pending(queued: [String], from name: String) -> Int {
        queued.filter { parse($0)?.from == name }.count
    }

    // MARK: Deciding

    /// The check of a request in the app: well formed, not from Main to itself, within the limits.
    static func decide(_ request: ReportRequest, workspaces: [Workspace], titles: [String: String], queued: (String) -> [String],
                       ledger: Ledger, now: Date) -> ReportDecision {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .reject("text is empty.") }
        guard text.count <= textLimit else { return .reject("text is \(text.count) characters; the limit is \(textLimit).") }
        guard abs(now.timeIntervalSince(request.created)) <= staleAfter else { return .reject("The report is too old.") }
        let workspace: Workspace
        switch target(argument: request.workspace, caller: request.source.workspace, in: workspaces) {
        case .success(let found): workspace = found
        case .failure(let error): return .reject(error.message)
        }
        if isSelf(request.source, workspace: workspace.id) {
            return .reject("You are the Main of \(workspace.name); a report goes to a Main from another agent. Say it in your own reply.")
        }
        let name = String(name(of: request.source, titles: titles).prefix(titleLimit))
        let caller = request.source.identity
        switch ledger.problem(caller: caller, text: text, pending: pending(queued: queued(workspace.id), from: name), now: now) {
        case .duplicate?: return .duplicate
        case .refused(let why)?: return .reject(why)
        case nil: return .deliver(workspace: workspace.id, name: name, prompt: prompt(from: name, title: request.title.map { String($0.prefix(titleLimit)) }, text: text))
        }
    }

    /// A report starts a turn when Main is idle and waits its turn otherwise, even while a permission prompt waits.
    static func route(busy: Bool, queued: Int) -> AgentInbox.Decision {
        if queued >= AgentInbox.queueLimit { return .reject("\(queued) messages are already queued for Main; nothing was sent.") }
        return busy || queued > 0 ? .queue : .start
    }

    static func replyText(_ decision: AgentInbox.Decision, workspace: String) -> String {
        switch decision {
        case .start: return "Sent to the Main of \(workspace); it is reading it now."
        case .queue: return "Queued for the Main of \(workspace); it reads it when it finishes what it is doing."
        case .reject(let why): return why
        }
    }

    static let duplicateText = "The same report was sent in the last few minutes, so this one was dropped."

    /// What Main is told about the reports it receives, in its system prompt.
    static let mainNote = PromptBuiltIns.mainReportNote.trimmingCharacters(in: .whitespacesAndNewlines)

    /// What every agent is told about reporting to Main.
    static let agentNote = "When you finish a job and the user may not be watching (a routine, a long run, work handed to you by Main), you can report to the workspace's Main "
        + "with send_to_main: a few lines with the outcome and what needs the user. It asks the user first unless they allowed it, and a routine without that permission is refused. "
        + "Send one report per job, never chat, and never from Main itself. When your session is for one Jira ticket, make the report one line that starts with the ticket key, "
        + "then its outcome (PASS, FAIL, BLOCKED or done) and a link."
}
