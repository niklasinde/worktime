import UserNotifications

/// Shows a decision's notification again when macOS has swept it away unanswered: banners leave after seconds, and a notification
/// the user cleared by mistake would otherwise be gone while the question still waits. Quiet each time, a few times, then it stays in the notch.
@MainActor
final class DecisionKeeper {
    static let shared = DecisionKeeper()
    private struct Entry {
        let first: Date
        var reposts = 0
        let repost: @MainActor () -> Void
    }
    private var entries: [String: Entry] = [:]
    private var timer: Timer?

    /// Starts keeping the notification with this identifier; `repost` shows it again, without a sound.
    func keep(_ identifier: String, first: Date = Date(), repost: @escaping @MainActor () -> Void) {
        guard Decisions.keepOnScreen() else { return }
        entries[identifier] = Entry(first: first, repost: repost)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DecisionKeeper.shared.check() }
        }
    }

    /// The decision was answered, dismissed or taken back.
    func release(_ identifier: String) {
        entries[identifier] = nil
        if entries.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func check() {
        let now = Date()
        let due = entries.filter { Decisions.repostDue(first: $0.value.first, reposts: $0.value.reposts, now: now) }
        guard !due.isEmpty else { return }
        Task {
            let delivered = Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
            for (identifier, entry) in due {
                entries[identifier]?.reposts += 1
                if !delivered.contains(identifier) { entry.repost() }
            }
        }
    }
}
