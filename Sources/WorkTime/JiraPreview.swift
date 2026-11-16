#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-jira <folder> --data-dir <folder>` saves PNGs of the Jira page with sample tickets, ticket
/// agents that work, wait and have an unseen result, its tabs and chips, and its empty and error states. It refuses to run without
/// `--data-dir`, so the real data is never touched.
enum JiraPreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--render-jira"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func run(to output: URL) -> Never {
        guard AppPaths.dataDirectory != nil else { fatalError("--render-jira needs --data-dir, so the real data is never touched") }
        NSApplication.shared.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = output.appendingPathComponent("jira.sqlite")
        ["", "-wal", "-shm"].forEach { try? FileManager.default.removeItem(atPath: database.path + $0) }
        guard let store = try? MeetingStore.open(at: database) else { exit(1) }
        let library = RecordingLibrary(store: store, folder: output.appendingPathComponent("empty", isDirectory: true))
        library.show(.jira)
        let window = MainWindow.makeWindow(MainView(recorder: Recorder(), processor: MeetingProcessor(notifier: nil, store: store), library: library,
                                                    activity: ActivityModel(store: store, tracker: ActivityTracker(store: store)),
                                                    playback: AudioPlayback()))
        window.setContentSize(NSSize(width: 1040, height: 760))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        Task { @MainActor in
            let model = JiraPageModel.shared
            @MainActor func shot(_ name: String, appearances: [NSAppearance.Name] = [.aqua, .darkAqua]) async {
                for appearance in appearances {
                    window.appearance = NSAppearance(named: appearance)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    PreviewRenderer.save(window, to: output.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            JiraModel.shared.showSample(configured: true)
            makeAgents(in: output)
            model.showSample(lists: samples, pullRequests: pullRequests)
            await shot("assigned")
            model.filter.status = .myTurn
            await shot("my-turn", appearances: [.aqua])
            model.filter.status = .blocked
            await shot("blocked", appearances: [.aqua])
            model.filter = JiraFilter(project: "QDLY", type: "Bug")
            await shot("filtered", appearances: [.aqua])
            model.filter = JiraFilter(query: "zzz")
            await shot("no-match", appearances: [.aqua])
            model.filter = JiraFilter()
            model.tab = .reported
            await shot("reported", appearances: [.aqua])
            model.tab = .assigned
            window.setContentSize(NSSize(width: 760, height: 700))
            await shot("narrow-window")
            window.setContentSize(NSSize(width: 1040, height: 760))
            model.showSample(lists: samples, pullRequests: pullRequests, error: .rateLimited)
            await shot("error-with-cache", appearances: [.aqua])
            model.showSample(lists: [:], error: .unauthorized, fetched: nil)
            await shot("error", appearances: [.aqua])
            JiraModel.shared.showSample(configured: false)
            model.showSample(lists: [:], fetched: nil)
            await shot("not-set-up")
            exit(0)
        }
        NSApplication.shared.run()
        exit(0)
    }

    /// One ticket agent that works, one that waits for a permission and one with a result not seen yet, in a store of their own.
    @MainActor
    private static func makeAgents(in output: URL) {
        let store = TopicAgentStore.shared, data = output.appendingPathComponent("jira-data", isDirectory: true)
        store.useSample(file: data.appendingPathComponent("topic-agents.json"), root: data.appendingPathComponent("Agents", isDirectory: true))
        let tickets = samples[.assigned] ?? []
        func agent(_ ticket: JiraTicket, _ items: [AgentEvent], busy: Bool, seen: Bool) {
            guard let opened = store.open(ticket: ticket) else { return }
            var transcript = [AgentItem(id: "user-0", kind: .user("Look at \(ticket.key) and summarise what\u{2019}s needed from me."))]
            items.forEach { AgentLogic.apply($0, to: &transcript) }
            store.load(opened.topic).preview(transcript, busy: busy, seen: seen)
        }
        agent(tickets[0], [.toolUse(id: "1", tool: "mcp__worktime__jira_issue", summary: tickets[0].key, detail: "")], busy: true, seen: true)
        agent(tickets[1], [.permissionRequest(id: "2", tool: "Bash", summary: "npm test", detail: "npm test")], busy: true, seen: true)
        agent(tickets[3], [.text("The export needs the new column; I drafted the release note."),
                           .result(sessionID: "preview-ticket", isError: false, text: "", turns: 2, model: "claude-sonnet-5-5", mode: .auto)],
              busy: false, seen: false)
    }

    private static func ticket(_ key: String, _ summary: String, _ status: String, _ category: JiraStatusCategory, type: String = "Task",
                               priority: String? = "Medium", assignee: String? = "Niklas Inde", ago: TimeInterval, labels: [String] = []) -> JiraTicket {
        JiraTicket(key: key, summary: summary, status: status, priority: priority, updated: Date().addingTimeInterval(-ago), type: type,
                   assignee: assignee, category: category, labels: labels)
    }

    static var samples: [JiraTab: [JiraTicket]] {
        let assigned = [
            ticket("QDLY-8332", "Release note for the new export of invoices to Gaia", "In Progress", .inProgress, priority: "High", ago: 1_800),
            ticket("QDLY-8301", "Rating conversion table as a grid of tiers and risk indicators", "In Progress", .inProgress, type: "Story", ago: 9_000),
            ticket("QDLY-8294", "Strawbay send guard rejects a valid journal number", "Review", .inProgress, type: "Bug", priority: "Highest", ago: 40_000),
            ticket("QDLY-8290", "Add the missing downgrade to the reminder fee migration", "To Do", .todo, type: "Maintenance", priority: "Low", ago: 90_000),
            ticket("ISD-4417", "Intrum UAT login fails after the SSO change", "Blocked", .inProgress, type: "Support", priority: "High", ago: 200_000,
                   labels: ["blocked"]),
            ticket("QDLY-8250", "Report deductions to the authority through the partner", "Done", .done, type: "Story", priority: nil, ago: 260_000),
        ]
        return [
            .assigned: assigned,
            .reported: [ticket("QDLY-8340", "Customers see a stale balance after a partial payment", "To Do", .todo, type: "Bug", assignee: "Anna Berg", ago: 20_000),
                        ticket("QDLY-8311", "Show the debtor's payment plan in the case view", "In Progress", .inProgress, type: "Story", assignee: "Katia Lind", ago: 70_000)],
            .watching: [ticket("QDLY-8120", "Move the print-house templates to the new address layout", "Review", .inProgress, type: "Story", assignee: "Johan Ek", ago: 150_000)],
        ]
    }

    static var pullRequests: [String: [GitHubPR]] {
        func pr(_ number: Int, _ repo: String, _ title: String) -> GitHubPR {
            GitHubPR(url: "https://github.com/acme/\(repo)/pull/\(number)", number: number, title: title, repo: "acme/\(repo)", updated: Date(), checks: .passed)
        }
        return ["QDLY-8332": [pr(872, "finq.admin-ui", "QDLY-8332: Release note")],
                "QDLY-8294": [pr(2462, "finq.api", "QDLY-8294: Guard"), pr(2470, "finq.api", "QDLY-8294: Follow-up")]]
    }
}
#endif
