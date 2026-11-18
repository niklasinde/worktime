import AppKit
import SwiftUI

/// Everything linked to everything: agents, tickets and pull requests with their branches and threads, by agent, ticket or pull request.
/// Links found by the app are dashed, the ones added by hand solid.
struct LinksView: View {
    let agents: [AgentState]
    @ObservedObject private var store = LinkStore.shared
    @ObservedObject private var directory = SessionRefDirectory.shared
    @AppStorage("linksMode") private var mode = LinkMode.agent
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var adding: String?
    @State private var draft = ""
    @State private var invalid = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let labels = LinkLabels(agents: Dictionary(agents.map { ($0.key, $0.title) }) { first, _ in first },
                                infos: directory.entries.compactMapValues(\.info))
        let rows = LinkRows.rows(store.table, mode: mode, labels: labels, including: agents.map { .agent($0.key) }, query: query)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) { ForEach(LinkMode.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, labels: labels)
                        Divider()
                    }
                }
            }
            .overlay { if rows.isEmpty { Text("No links").foregroundStyle(.secondary) } }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task(id: lookupKey(rows)) { await directory.ensure(refs(rows), skip: []) }
    }

    private func refs(_ rows: [LinkRow]) -> [SessionRef] {
        Array(rows.flatMap { [$0.entity] + $0.chips.map(\.entity) }.prefix(60).compactMap(Self.ref))
    }

    private func lookupKey(_ rows: [LinkRow]) -> String { refs(rows).map(\.cacheKey).joined(separator: ",") }

    private static func ref(_ entity: LinkEntity) -> SessionRef? {
        switch entity.kind {
        case .jira: .jira(entity.id)
        case .githubPR: GitHubLink.pasted(entity.id).map(SessionRef.init)
        default: nil
        }
    }

    private func rowView(_ row: LinkRow, labels: LinkLabels) -> some View {
        let isOpen = expanded.contains(row.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    LinkEntityLabel(entity: row.entity, labels: labels, bold: true) { open(row.entity) }
                    if let detail = labels.detail(row.entity) { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                .frame(width: 220, alignment: .leading)
                FlowLayout(spacing: 6) {
                    ForEach(row.chips) { chip in
                        HStack(spacing: 2) {
                            LinkEntityLabel(entity: chip.entity, labels: labels, bold: false) { open(chip.entity) }
                            Button { store.remove(LinkPair(row.entity, chip.entity)) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                                .help("Remove this link")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(chip.source == .manual ? Color.accentColor : Color.secondary.opacity(0.5),
                                                        style: StrokeStyle(lineWidth: 1, dash: chip.source == .manual ? [] : [3, 2])))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { toggleAdding(row.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Link a ticket or pull request: paste a Jira key or a pull request address")
                if !row.related.isEmpty {
                    Button { toggle(row.id) } label: { Image(systemName: isOpen ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless)
                        .help("\(row.related.count) more reached through these")
                }
            }
            if adding == row.id { addField(row) }
            if isOpen {
                FlowLayout(spacing: 6) {
                    ForEach(row.related) { reach in
                        LinkEntityLabel(entity: reach.entity, labels: labels, bold: false) { open(reach.entity) }
                            .opacity(0.7)
                            .help("Through \(labels.name(reach.via))")
                    }
                }
                .padding(.leading, 230)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func addField(_ row: LinkRow) -> some View {
        HStack {
            TextField("Jira key or pull request address", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(to: row) }
            if invalid { Text("Not a Jira key or pull request").font(.caption).foregroundStyle(.red) }
        }
        .padding(.leading, 230)
    }

    private func toggle(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
    }

    private func toggleAdding(_ id: String) {
        adding = adding == id ? nil : id
        draft = ""
        invalid = false
    }

    private func add(to row: LinkRow) {
        guard let other = LinkTargets.entity(from: draft), other != row.entity else { return invalid = true }
        store.add(LinkPair(row.entity, other))
        adding = nil
        draft = ""
    }

    private func open(_ entity: LinkEntity) {
        switch entity.kind {
        case .githubPR:
            guard let target = GitHubLink.pasted(entity.id) else { return }
            dismiss()
            AgentModel.openPullRequestLink?(target)
        case .jira:
            dismiss()
            AgentModel.openJiraLink?(entity.id)
        case .agent:
            dismiss()
            AgentHub.shared.show(entity.id)
        case .slackThread:
            URL(string: entity.id).map { NSWorkspace.shared.open($0) }
        default: break
        }
    }
}

private struct LinkEntityLabel: View {
    let entity: LinkEntity
    let labels: LinkLabels
    let bold: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(labels.name(entity)).font(.system(size: 11, weight: bold ? .semibold : .regular, design: bold ? .monospaced : .default)).lineLimit(1)
                if let status = labels.status(entity) { StatusChip(text: status.text, kind: status.kind) }
            }
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch entity.kind {
        case .agent: "chevron.left.forwardslash.chevron.right"
        case .jira: "checklist"
        case .githubPR: "arrow.triangle.pull"
        case .branch: "arrow.triangle.branch"
        case .slackThread: "bubble.left"
        case .meeting: "waveform"
        default: "link"
        }
    }
}
