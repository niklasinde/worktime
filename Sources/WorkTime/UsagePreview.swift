#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `WorkTime --render-usage <folder>` saves PNGs of the Usage page and its settings, with made-up calls and plan limits.
enum UsagePreview {
    static func outputFolder(_ arguments: [String]) -> URL? {
        PhoneCommandLine.value("--render-usage", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func run(to output: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await render(to: output)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func sample(now: Date) -> [UsageRecord] {
        let opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5"
        var records: [UsageRecord] = []
        func add(_ day: Int, _ hour: Int, kind: UsageKind, key: String?, name: String, workspace: String?, models: [String: UsageModelTotals], turns: Int) {
            let calendar = Calendar.current
            let date = calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) ?? now) ?? now
            var totals = UsageTotals(models: models)
            totals.turns = turns
            records.append(UsageRecord(id: "\(records.count)", date: date, session: "s\(records.count)", kind: kind, key: key, name: name, workspace: workspace, totals: totals))
        }
        func model(_ output: Int, _ cost: Double) -> UsageModelTotals {
            UsageModelTotals(input: 1_200, output: output, cacheRead: output * 40, cacheWrite: output * 3, cost: cost)
        }
        for day in 0..<14 {
            add(day, 9, kind: .routine, key: "r1", name: "Morning brief", workspace: "alpha", models: [opus: model(900, 0.35 + Double(day % 3) * 0.05)], turns: 2)
            add(day, 11, kind: .assistant, key: "assistant:beta:reviewer", name: "Reviewer", workspace: "beta",
                models: [sonnet: model(9_000, 0.8 + Double(day % 4) * 0.2), haiku: model(800, 0.04)], turns: 14)
            if day % 2 == 0 {
                add(day, 14, kind: .automation, key: "a1", name: "Review requests", workspace: "beta", models: [sonnet: model(700, 0.12)], turns: 2)
                add(day, 15, kind: .main, key: "main:alpha", name: "Main", workspace: "alpha", models: [opus: model(6_500, 1.6)], turns: 9)
            }
            add(day, 16, kind: .summary, key: nil, name: "Meeting summary", workspace: nil, models: [sonnet: model(1_400, 0.06)], turns: 1)
        }
        return records
    }

    @MainActor
    private static func render(to output: URL) async {
        let log = UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-preview-\(UUID().uuidString).jsonl"))
        let now = Date()
        sample(now: now).forEach(log.append)
        let store = UsageStore(log: log, defaults: UserDefaults(suiteName: "WorkTimeUsagePreview") ?? .standard, alerts: false, now: now)
        let plan = UsagePlanModel()
        let soon = now.addingTimeInterval(4 * 3_600 + 55 * 60), later = now.addingTimeInterval(2 * 86_400 + 19 * 3_600)
        plan.preview(.plan(UsagePlan(subscription: "team", windows: [
            UsagePlan.Window(id: "five_hour", title: "5-hour limit", percent: 24, resets: soon),
            UsagePlan.Window(id: "seven_day", title: "Weekly \u{00B7} all models", percent: 67, resets: later),
            UsagePlan.Window(id: "model:Orchid", title: "Weekly \u{00B7} Orchid", percent: 91, resets: later),
        ], extra: UsagePlan.Extra(percent: 4.04, used: 4.04, limit: 100, currency: "EUR"))))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            await save(UsagePage(store: store, plan: plan).padding(24).frame(width: 760).background(.background), size: NSSize(width: 760, height: 2_000),
                       appearance: appearance, to: output.appendingPathComponent("usage-page-\(name).png"))
        }
        await save(UsageSettings().padding(24).frame(width: 760).background(.background), size: NSSize(width: 760, height: 520), appearance: .aqua,
                   to: output.appendingPathComponent("usage-settings-light.png"))
        let line = AgentLogic.resultLine(turns: 3, model: "claude-sonnet-5-5", mode: .auto,
                                         usage: UsageTotals(models: [UsageModelTotals.sampleName: UsageModelTotals(input: 1_000, output: 40_000, cacheRead: 90_000, cost: 0.18)], reportedCost: 0.18),
                                         display: UsageDisplay())
        print("footer: \(line)")
    }

    @MainActor
    private static func save<Content: View>(_ view: Content, size: NSSize, appearance: NSAppearance.Name, to url: URL) async {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setContentSize(size)
        window.appearance = NSAppearance(named: appearance)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        PreviewRenderer.save(window, to: url)
        window.orderOut(nil)
    }
}

private extension UsageModelTotals {
    static let sampleName = "claude-sonnet-5-5"
}
#endif
