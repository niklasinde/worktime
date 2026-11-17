import AppKit
import SwiftUI

enum AgentActionTarget {
    case here
    case assistant(AssistantEntry)
}

/// What the action rows of one agent's transcript need from it.
struct AgentActionContext {
    /// The agent's saved key, under which clicked actions are kept.
    let agent: String
    let assistants: [AssistantEntry]
    /// Sends the action; returns why it could not be.
    let run: (AgentAction, AgentActionTarget) async -> String?
}

private struct AgentActionsKey: EnvironmentKey {
    static let defaultValue: AgentActionContext? = nil
}

extension EnvironmentValues {
    var agentActions: AgentActionContext? {
        get { self[AgentActionsKey.self] }
        set { self[AgentActionsKey.self] = newValue }
    }
}

/// The actions already clicked, kept between runs of the app.
@MainActor
final class AgentActionStore: ObservableObject {
    static let shared = AgentActionStore()
    static let key = "agentActionOutcomes"

    @Published private(set) var book: AgentActionOutcomes.Book

    init() { book = AgentActionOutcomes.decode(AgentModel.defaults.data(forKey: Self.key)) }

    func outcome(agent: String, action: String) -> AgentActionOutcome? { book[AgentActionOutcomes.key(agent: agent, action: action)] }

    func record(_ outcome: AgentActionOutcome, agent: String, action: String) {
        book = AgentActionOutcomes.record(outcome, agent: agent, action: action, in: book)
        AgentModel.defaults.set(AgentActionOutcomes.encode(book), forKey: Self.key)
    }
}

/// An agent's reply with its action blocks as rows of buttons; without a context to send from, the blocks stay code.
struct AgentReply: View {
    let text: String
    let linkify: (String) -> String
    @Environment(\.agentActions) private var context

    var body: some View {
        let segments = context == nil ? [AgentActions.Segment.markdown(text)] : AgentActions.segments(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text): AnswerText(text: linkify(text))
                case .action(let action): if let context { AgentActionRow(action: action, context: context) }
                }
            }
        }
    }
}

struct AgentActionRow: View {
    let action: AgentAction
    let context: AgentActionContext
    @ObservedObject private var store = AgentActionStore.shared
    @State private var showsPrompt = false
    @State private var working = false
    @State private var problem: String?

    private var outcome: AgentActionOutcome? { store.outcome(agent: context.agent, action: action.id) }
    private var suggested: AssistantEntry? { AgentActions.suggested(action.assistant, in: context.assistants) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text(action.title).fontWeight(.medium).textSelection(.enabled) } icon: { Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary) }
            HStack(spacing: 10) { if let outcome { sent(outcome) } else { buttons } }
            HStack(spacing: 12) {
                Button(showsPrompt ? "Hide instructions" : "Show instructions") { showsPrompt.toggle() }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(action.prompt, forType: .string)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            if showsPrompt {
                Text(action.prompt)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    @ViewBuilder private var buttons: some View {
        Button("Do it here") { run(.here) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(working)
            .help("Sends the instructions to this agent as your next message")
        if let suggested {
            Menu("Ask \(suggested.role.name)") { assistantItems } primaryAction: { run(.assistant(suggested)) }
                .controlSize(.small)
                .fixedSize()
                .disabled(working)
                .help("Sends the instructions to \(suggested.role.name)")
        } else {
            Menu("Ask an assistant\u{2026}") { assistantItems }
                .controlSize(.small)
                .fixedSize()
                .disabled(working || context.assistants.isEmpty)
                .help("Sends the instructions to one of your assistants")
        }
    }

    @ViewBuilder private var assistantItems: some View {
        ForEach(context.assistants) { entry in
            Button(entry.role.name) { run(.assistant(entry)) }
        }
    }

    @ViewBuilder private func sent(_ outcome: AgentActionOutcome) -> some View {
        Label(outcome.label, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
        if let key = outcome.assistant { Button("Open") { AgentHub.shared.show(key) }.buttonStyle(.link).font(.callout) }
    }

    private func run(_ target: AgentActionTarget) {
        working = true
        problem = nil
        Task {
            problem = await context.run(action, target)
            working = false
        }
    }
}
