import Foundation

/// The tools unattended runs needed that their assistants' lists leave out, kept until the user adds them or dismisses them, and the
/// notification that asks.
@MainActor
final class RoleToolSuggestionStore: ObservableObject {
    static let shared = RoleToolSuggestionStore()
    /// The agent key the notification's buttons carry, which is not an agent's.
    nonisolated static let agentKey = "role-tool-suggestion"
    private static let dismissedKey = "agentRoleToolDismissed"

    @Published private(set) var pending: [RoleToolSuggestion]
    private var dismissed: Set<String>
    private var announced: Set<String> = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? AgentModel.defaults
        self.defaults = defaults
        pending = RoleToolSuggestions.decode(defaults.data(forKey: RoleToolSuggestions.key))
        dismissed = Set(defaults.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    func record(_ suggestion: RoleToolSuggestion) {
        guard RoleToolSuggestions.shouldAsk(suggestion, pending: pending, dismissed: dismissed) else { return }
        pending = RoleToolSuggestions.adding(suggestion, to: pending)
        defaults.set(RoleToolSuggestions.encode(pending), forKey: RoleToolSuggestions.key)
    }

    /// Tells the user about each suggestion not yet told, once the run that needed it is over.
    func announceNew() {
        for suggestion in pending where announced.insert(suggestion.id).inserted {
            let text = RoleToolSuggestions.text(suggestion)
            let identifier = RoleToolSuggestions.identifier(suggestion)
            Notifier.postRoleSuggestion(id: suggestion.id, text: text, identifier: identifier)
            DecisionKeeper.shared.keep(identifier) { Notifier.postRoleSuggestion(id: suggestion.id, text: text, identifier: identifier, quiet: true) }
        }
    }

    /// Add puts the tool on the assistant's list; Dismiss forgets it and does not ask again for that assistant and tool.
    func respond(_ id: String, add: Bool) {
        guard let suggestion = pending.first(where: { $0.id == id }) else { return }
        if add, let entry = AssistantStore.shared.entry(suggestion.assistant) { AssistantStore.shared.addTool(suggestion.tool, to: entry) }
        if !add { dismissed.insert(id); defaults.set(Array(dismissed), forKey: Self.dismissedKey) }
        remove(id)
    }

    private func remove(_ id: String) {
        pending = RoleToolSuggestions.removing(id, from: pending)
        defaults.set(RoleToolSuggestions.encode(pending), forKey: RoleToolSuggestions.key)
        announced.remove(id)
        Notifier.withdraw(identifiers: [RoleToolSuggestions.identifier(id: id)])
    }
}
