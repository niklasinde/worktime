import Foundation

/// The app's own facts for `app_info`, written next to `agents.json`.
struct AppInfo: Codable, Equatable {
    struct Workspace: Codable, Equatable {
        var id: String
        var name: String
        var spaces: [String]
    }

    struct Work: Codable, Equatable {
        var kind: String
        var title: String
        var session: String?
        var ticket: String?
        var since: Date?
    }

    struct PlanWindow: Codable, Equatable {
        var title: String
        var percent: Double
        var resets: Date?
    }

    var written: Date
    var version: String
    var build: String?
    var commit: String?
    var buildDate: Date?
    var pid: Int32
    var started: Date
    var dataFolder: String
    var diagnosticsFolder: String? = nil
    var schemaVersion: Int
    var workspaces: [Workspace]
    var sidecar: String
    var working: [Work]
    var waiting: [Work]
    var queuedPrompts: Int
    var recording: Bool
    var plan: [PlanWindow]?
    var planFetched: Date?
}

enum AppInfos {
    static let fileName = "app.json"
    static let staleAfter: TimeInterval = 120

    static func encode(_ info: AppInfo) -> Data { AgentInbox.encode(info) }

    static func decode(_ data: Data?) -> AppInfo? { data.flatMap { AgentInbox.decode(AppInfo.self, from: $0) } }

    /// The sessions doing something right now, and those waiting for the user, from the agents' state.
    static func work(_ agents: [AgentState], routines running: [String] = []) -> (working: [AppInfo.Work], waiting: [AppInfo.Work]) {
        func entry(_ state: AgentState) -> AppInfo.Work {
            AppInfo.Work(kind: AgentFilter.kind(of: state), title: state.title, session: state.sessionID,
                         ticket: state.jiraKey, since: state.updatedAt)
        }
        let live = agents.filter { $0.archived != true }
        let working = live.filter { $0.status == .working }.map(entry)
            + running.map { AppInfo.Work(kind: "routine", title: $0, session: nil, ticket: nil, since: nil) }
        return (working, live.filter { $0.status == .waiting }.map(entry))
    }

    /// Whether quitting now would cut something off: a working session, a prompt waiting its turn, a routine, a recording.
    static func restartInterrupts(_ info: AppInfo) -> Bool { !info.working.isEmpty || info.queuedPrompts > 0 || info.recording }

    /// Whether the process that wrote the file still exists, as far as the file says.
    static func isFresh(_ info: AppInfo, now: Date) -> Bool { now.timeIntervalSince(info.written) <= staleAfter }

    static func uptime(_ info: AppInfo, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(info.started)))
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 0))m"
    }

    static func markdown(_ info: AppInfo, now: Date, alive: Bool, mcpSchema: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["WorkTime \(info.version)" + (info.build.map { " (build \($0))" } ?? "")
                     + (info.commit.map { " \u{00B7} commit \($0)" } ?? info.buildDate.map { " \u{00B7} built \(formatter.string(from: $0))" } ?? "")]
        lines.append("pid \(info.pid)" + (alive ? "" : " (not running)") + " \u{00B7} started \(formatter.string(from: info.started)) \u{00B7} up \(uptime(info, now: now))")
        lines.append("data folder: \(info.dataFolder)")
        if let diagnostics = info.diagnosticsFolder { lines.append("performance diagnostics: \(diagnostics)") }
        lines.append("sidecar: \(info.sidecar)")
        lines.append("workspaces: " + info.workspaces.map { $0.id + ($0.spaces.isEmpty ? "" : " (spaces: " + $0.spaces.joined(separator: ", ") + ")") }.joined(separator: "; "))
        lines.append("\(info.working.count) working, \(info.waiting.count) waiting for the user, \(info.queuedPrompts) prompt\(info.queuedPrompts == 1 ? "" : "s") queued"
                     + (info.recording ? ", recording a meeting" : ""))
        if restartInterrupts(info) {
            lines.append("A restart now WOULD interrupt:")
            for work in info.working { lines.append("- \(work.kind) \(work.title)" + (work.ticket.map { " (\($0))" } ?? "") + (work.session.map { " session \($0)" } ?? "")) }
            if info.queuedPrompts > 0 { lines.append("- \(info.queuedPrompts) queued prompt\(info.queuedPrompts == 1 ? "" : "s")") }
            if info.recording { lines.append("- a meeting recording") }
        } else {
            lines.append("A restart now would not interrupt running work.")
        }
        if !isFresh(info, now: now) { lines.append("The state was written \(ClaudePlugin.ago(info.written, now: now)); WorkTime may not be running.") }
        if let plan = info.plan, !plan.isEmpty {
            lines.append("plan windows" + (info.planFetched.map { " (read \(ClaudePlugin.ago($0, now: now)))" } ?? "") + ": "
                         + plan.map { "\($0.title) \(Int($0.percent))%" + ($0.resets.map { ", \(UsagePlan.resetText($0, now: now))" } ?? "") }.joined(separator: "; "))
        }
        lines.append("MCP schema: app \(info.schemaVersion), this connection \(mcpSchema)"
                     + (info.schemaVersion != mcpSchema ? ". They differ: reconnect the worktime MCP (/mcp) to pick up the app's current tools." : "."))
        return lines.joined(separator: "\n") + "\n"
    }
}
