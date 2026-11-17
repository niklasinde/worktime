import Foundation

/// Finds the agent a notification came from and does what the user tapped, also while the app is in the background.
@MainActor
final class AgentAttentionCenter {
    static let shared = AgentAttentionCenter()
    private struct Entry { weak var model: AgentModel? }
    private var models: [String: Entry] = [:]

    func register(_ model: AgentModel, id: String) {
        models[id] = Entry(model: model)
    }

    /// A button or reply of a notification; an agent no longer there (the app was restarted since) is opened instead.
    func respond(agent: String, request: String?, action: String, text: String?) {
        guard let model = models[agent]?.model else { return AgentHub.shared.show(agent) }
        switch AgentAttention.response(action: action, text: text) {
        case .allow: if let request { model.answer(permission: request, allow: true) }
        case .allowSession: if let request { model.answer(permission: request, allow: true, session: true) }
        case .deny: if let request { model.answer(permission: request, allow: false) }
        case .answer(let reply): model.reply(reply)
        case .stop: model.cancelFromMain()
        case .open: AgentHub.shared.show(agent)
        }
    }
}
