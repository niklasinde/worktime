import Foundation

/// Finds the agent a notification came from and does what the user tapped, also while the app is in the background.
/// It also lists the approvals still waiting, so the notch bar can show them with the same buttons.
@MainActor
final class AgentAttentionCenter: ObservableObject {
    static let shared = AgentAttentionCenter()
    private struct Entry { weak var model: AgentModel? }
    private var models: [String: Entry] = [:]

    struct Approval: Identifiable, Equatable {
        var id: String { AgentAttention.approvalIdentifier(agent: agent, permission: permission) }
        let agent: String
        let permission: String
        let title: String
        let body: String
        let sessionOffered: Bool
        let created: Date
    }

    @Published private(set) var approvals: [Approval] = []

    func add(_ approval: Approval) {
        guard !approvals.contains(where: { $0.id == approval.id }) else { return }
        approvals.append(approval)
    }

    func remove(agent: String, permission: String? = nil) {
        approvals.removeAll { $0.agent == agent && (permission == nil || $0.permission == permission) }
    }

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
