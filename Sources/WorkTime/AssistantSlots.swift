import Foundation

/// Keeps the number of assistant sessions working at once within the setting, and an assistant's own `concurrency`: a prompt from Main for
/// a session that would go over waits here until one finishes. A prompt the user types is never held back.
@MainActor
final class AssistantSlots {
    static let shared = AssistantSlots()
    private struct Entry { weak var model: AgentModel? }
    private var waiting: [Entry] = []

    private var models: [AgentModel] { Array(AssistantStore.shared.models.values) + Array(TopicAgentStore.shared.models.values) }

    private func running(excluding model: AgentModel? = nil) -> [String] {
        models.filter { $0 !== model && $0.busy }.compactMap { $0.slotRole?.key }
    }

    func hasRoom(for model: AgentModel) -> Bool {
        guard let slot = model.slotRole else { return true }
        return SessionSlots.hasRoom(role: slot.key, roleLimit: slot.limit, running: running(excluding: model), limit: SessionSlots.limit())
    }

    func wait(_ model: AgentModel) {
        guard !waiting.contains(where: { $0.model === model }) else { return }
        waiting.append(Entry(model: model))
        AgentStateWriter.shared.changed()
    }

    func forget(_ model: AgentModel) {
        waiting.removeAll { $0.model === model || $0.model == nil }
        AgentStateWriter.shared.changed()
    }

    /// A session finished or was closed: the prompts that waited start, oldest first, as far as there is room.
    func changed() {
        waiting.removeAll { $0.model == nil }
        let candidates = waiting.enumerated().compactMap { index, entry -> (id: String, role: String, roleLimit: Int?)? in
            guard let slot = entry.model?.slotRole else { return nil }
            return (String(index), slot.key, slot.limit)
        }
        let start = Set(SessionSlots.startable(waiting: candidates, running: running(), limit: SessionSlots.limit()))
        let starting = waiting.enumerated().filter { start.contains(String($0.offset)) }.compactMap(\.element.model)
        waiting.removeAll { entry in starting.contains { $0 === entry.model } }
        starting.forEach { $0.startFromSlot() }
        AgentStateWriter.shared.changed()
    }
}
