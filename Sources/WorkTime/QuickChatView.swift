import AppKit
import SwiftUI

/// The quick chat panel: a prompt on top, and under it the turn in progress with its approvals.
struct QuickChatView: View {
    @ObservedObject var panel: QuickChatPanel

    var body: some View {
        Group {
            if let model = panel.model { QuickChatContent(panel: panel, model: model).id(ObjectIdentifier(model)) }
        }
        .frame(width: QuickChatPanel.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

private struct QuickChatContent: View {
    static let collapsedHeight: CGFloat = 320
    static let expandedHeight: CGFloat = 520

    @ObservedObject var panel: QuickChatPanel
    @ObservedObject var model: AgentModel
    @State private var height: CGFloat = 26
    @State private var expanded = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let shown = QuickChat.shown(model.items, expanded: expanded, busy: model.busy, updated: model.updated, now: Date())
        VStack(alignment: .leading, spacing: 0) {
            prompt
            mentions
            AgentImageChips(model: model).padding(.bottom, 8)
            AgentPendingList(model: model)
            if !shown.isEmpty || model.busy {
                Divider()
                transcript(shown)
            }
            if !model.items.isEmpty {
                Divider()
                footer(shown)
            }
        }
        .transcriptTypography()
        .environment(\.openURL, OpenURLAction { model.open($0) })
    }

    private var hasContent: Bool { !model.draft.trimmingCharacters(in: .whitespaces).isEmpty || !model.images.isEmpty }

    private var prompt: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            ChatComposer(text: $model.draft, height: $height, placeholder: model.busy ? "Queue a follow-up message" : QuickChat.placeholder,
                         maxLines: 4, attach: model.attach, problem: model.imageProblem) { model.submit() }
                .frame(height: height)
            workspaceMenu
            if model.busy {
                Button { model.stop() } label: { Image(systemName: "stop.fill").frame(width: 34, height: 34) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor))
                    .help("Stop")
            }
            if !model.busy || hasContent {
                Button { model.send() } label: { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 34, height: 34) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hasContent ? Color.accentColor : Color.secondary.opacity(0.35)))
                    .help(model.busy ? "Queue message (Return)" : "Send (Return)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(panel.choices, id: \.id) { choice in
                Button { panel.select(choice.id) } label: {
                    if choice.id == panel.workspace { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                }
            }
            Divider()
            Button("New Session") { model.newSession() }.disabled(model.items.isEmpty && model.sessionID == nil)
        } label: {
            Text(panel.choices.first { $0.id == panel.workspace }?.name ?? "Main")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Which Main to talk to")
    }

    @ViewBuilder private var mentions: some View {
        if !model.mentionMatches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.mentionMatches, id: \.self) { path in
                    Button { model.draft = AgentLogic.insertMention(path, into: model.draft) } label: {
                        Label(path, systemImage: "doc.text")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(path == model.mentionMatches.first ? Color.primary.opacity(0.07) : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .padding(.horizontal, 14)
        }
    }

    private func row(_ item: AgentItem) -> AgentItemRow {
        AgentItemRow(item: item, folder: model.folder, answer: { model.answer(item, allow: $0, always: $1, session: $2) },
                     addTool: { model.answer(item, allow: true, add: true) },
                     move: { if let folder = $0 { model.move(to: folder) } else { model.changeFolder() } })
    }

    private func transcript(_ shown: [AgentItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(AgentToolGroups.blocks(shown)) { block in
                        switch block {
                        case .item(let item): row(item)
                        case .tools(_, let items, let label): AgentToolGroup(label: label, items: items, row: row)
                        case .refused(_, let items, let label): AgentToolGroup(label: label, items: items, row: row, icon: "xmark.circle")
                        }
                    }
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                    if let problem = model.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 40), expanded ? Self.expandedHeight : Self.collapsedHeight))
            .environment(\.agentActions, model.actionContext)
            .onChange(of: model.items) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func footer(_ shown: [AgentItem]) -> some View {
        HStack(spacing: 14) {
            Button { panel.openInApp() } label: { Label("Open in WorkTime", systemImage: "arrow.up.forward.app") }
                .help("Continue on the Main page; Back returns to where you were")
            if expanded || QuickChat.hasMore(model.items, shown: shown) {
                Button { expanded.toggle() } label: { Text(expanded ? "Show less" : "Show conversation") }
            }
            Spacer()
            Text("esc to close").foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
