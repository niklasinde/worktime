import Foundation

/// The questions "this assistant already has a session for the ticket: reuse it or start a new one?" that wait for the user: kept so they
/// survive a restart, shown as a card in Main's chat, in the notch bar and as a notification with buttons, and answered from any of them.
@MainActor
final class TicketAskStore: ObservableObject {
    static let shared = TicketAskStore()
    /// The agent key the notification's buttons carry, which is not an agent's.
    nonisolated static let agentKey = "ticket-ask"

    @Published private(set) var pending: [TicketAsk]
    private var waiters: [String: CheckedContinuation<TicketSessions.Answer?, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? AgentModel.defaults
        self.defaults = defaults
        pending = TicketAsks.live(TicketAsks.decode(defaults.data(forKey: TicketAsks.storeKey)), now: Date())
        pending.forEach(arm)
    }

    /// Shows the questions that survived a restart again.
    func restore() { pending.forEach(announce) }

    func asks(in workspace: String?) -> [TicketAsk] {
        pending.filter { workspace == nil || $0.workspace == workspace }
    }

    /// Whether the ticket or pull request has a question waiting, for its row in the agents list.
    func isAsking(subject: SessionSubject) -> Bool {
        pending.contains { TicketAsks.pending(assistant: $0.assistant, subject: subject, in: [$0]) != nil }
    }

    /// Puts the question to the user and waits for the answer; nil when the time ran out.
    func ask(_ ask: TicketAsk) async -> TicketSessions.Answer? {
        pending.append(ask)
        save()
        announce(ask)
        return await withCheckedContinuation { continuation in
            waiters[ask.id] = continuation
            arm(ask)
        }
    }

    /// An answer from the card, the notch or the notification. A question that outlived a restart has nobody waiting for it any more; its
    /// prompt is sent all the same.
    func respond(_ id: String, _ answer: TicketSessions.Answer) {
        guard let ask = pending.first(where: { $0.id == id }) else { return }
        remove(id)
        timers.removeValue(forKey: id)?.cancel()
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: answer) } else {
            Task { @MainActor in _ = await TopicAgentStore.shared.finish(ask: ask, answer: answer) }
        }
    }

    /// Opens the session the question is about.
    func open(_ id: String) {
        guard let ask = pending.first(where: { $0.id == id }) else { return }
        AgentHub.shared.show(ask.existing.key)
    }

    private func arm(_ ask: TicketAsk) {
        let wait = max(0, ask.deadline.timeIntervalSinceNow)
        timers[ask.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timeout(ask.id)
        }
    }

    private func timeout(_ id: String) {
        remove(id)
        timers[id] = nil
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }

    private func announce(_ ask: TicketAsk) {
        let now = Date(), identifier = TicketAsks.identifier(ask.id)
        let approval = AgentAttentionCenter.Approval(agent: Self.agentKey, permission: ask.id, title: ask.title, body: ask.body(now: now), sessionOffered: false,
                                                     created: now, ticketAsk: true)
        AgentAttentionCenter.shared.add(approval)
        guard AgentAttention.enabled(), AgentHub.shared.mains[ask.workspace]?.isBeingWatched != true else { return }
        let text = (title: ask.title, body: ask.body(now: now))
        Notifier.postTicketAsk(id: ask.id, text: text, identifier: identifier)
        DecisionKeeper.shared.keep(identifier) { Notifier.postTicketAsk(id: ask.id, text: text, identifier: identifier, quiet: true) }
    }

    private func remove(_ id: String) {
        pending.removeAll { $0.id == id }
        save()
        AgentAttentionCenter.shared.remove(agent: Self.agentKey, permission: id)
        Notifier.withdraw(identifiers: [TicketAsks.identifier(id)])
    }

    private func save() { defaults.set(TicketAsks.encode(pending), forKey: TicketAsks.storeKey) }
}
