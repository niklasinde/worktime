import AppKit
import SwiftUI

/// The Jira page: the user's tickets by tab, each with the one agent of its ticket, laid out like the GitHub page.
struct JiraView: View {
    @ObservedObject var model: JiraPageModel
    @ObservedObject private var writer = AgentStateWriter.shared
    @ObservedObject private var topics = TopicAgentStore.shared
    @AppStorage("jiraListWidth") private var listWidth = GitHubLayout.defaultListWidth
    @State private var showsDetail = false
    @FocusState private var focused: Bool

    private static let gutter: CGFloat = 16

    private var selected: String? { model.selected }

    var body: some View {
        VStack(spacing: 0) {
            JiraBanners(model: model)
            GeometryReader { proxy in
                let list = model.configured && model.hasData ? GitHubLayout.listWidth(listWidth, in: proxy.size.width) : 0
                if list > 0 {
                    HStack(spacing: 0) {
                        page.frame(width: list)
                        ColumnSplitter(width: $listWidth, current: list, total: proxy.size.width)
                        detail(back: nil)
                    }
                } else if showsDetail, model.configured, model.hasData, selected != nil {
                    detail(back: { showsDetail = false })
                } else {
                    page
                }
            }
        }
        .onAppear {
            listWidth = GitHubLayout.repairedWidth(listWidth)
            model.linkPullRequests()
            Task { await model.refresh() }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, model.hasData { JiraErrorBanner(error: error) }
            if let error = model.queryError { JiraErrorBanner(error: error) }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func detail(back: (() -> Void)?) -> some View {
        if let key = selected {
            JiraDetailView(key: key, model: model, back: back).id(key).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GitHubEmptyState(icon: "ticket", title: "Select a ticket",
                             text: "Click one in the list, or use the arrow keys. Return opens its agent.") { EmptyView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Jira").font(.system(size: 20, weight: .medium))
                Spacer()
                if model.configured { refreshControls }
            }
            if model.configured, model.error == nil || model.hasData {
                FlowLayout(spacing: 2) {
                    ForEach(JiraTab.allCases) { tab in
                        Button(tab.title) { model.tab = tab }.buttonStyle(PillButtonStyle(selected: model.tab == tab))
                    }
                }
                .padding(.top, 8)
                .padding(.leading, -8)
                HStack(spacing: 8) {
                    Text(model.title).font(.system(size: 22, weight: .medium))
                    if model.querying { ProgressView().controlSize(.small) }
                }
                .padding(.top, 8)
                JiraFilterBar(model: model).controlSize(.small).padding(.top, 6)
                statusChips.padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    searchRow(compact: false)
                    searchRow(compact: true)
                }
                .controlSize(.small)
                .onSubmit { model.runRaw() }
                .padding(.top, 10)
                if model.isRaw {
                    Text("Runs the JQL after jql: when you press Return, over all of Jira.").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var refreshControls: some View {
        HStack(spacing: 8) {
            if let fetched = model.fetched {
                Text("Updated \(GitHubLogic.updatedText(fetched, now: Date()))").font(.callout).foregroundStyle(.tertiary)
            }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.refreshing)
                .help("Fetch your tickets now")
        }
    }

    private var statusChips: some View {
        let counts = model.statusCounts
        return FlowLayout(spacing: 4) {
            ForEach(JiraStatusTab.allCases.filter { $0 == .all || $0 == model.filter.status || (counts[$0] ?? 0) > 0 }) { chip in
                Button { model.filter.status = chip } label: {
                    HStack(spacing: 4) {
                        Text(chip.title)
                        Text("\(counts[chip] ?? 0)").foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .buttonStyle(NotchChipStyle(selected: model.filter.status == chip))
            }
        }
    }

    private func searchRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            SearchField(text: $model.filter.query).frame(minWidth: compact ? nil : 150).help("Search, or type jql: and a JQL query")
            OpenTicketButton(model: model, compact: compact)
        }
    }

    @ViewBuilder private var content: some View {
        if !model.configured {
            GitHubEmptyState(icon: "ticket", title: "Your Jira tickets, in one place",
                             text: "Set up Jira in Settings to list your tickets and open one agent per ticket. Nothing is uploaded.") {
                Button("Set Up Jira\u{2026}") { SettingsModel.shared.show(anchor: .jira) }.buttonStyle(.borderedProminent)
            }
        } else if let error = model.error, !model.hasData {
            GitHubEmptyState(icon: "exclamationmark.triangle", title: "Could not fetch tickets", text: error.message) {
                Button("Try Again") { Task { await model.refresh() } }
            }
        } else if model.visible.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        let fetching = model.querying || (model.refreshing && !model.hasData)
        return GitHubEmptyState(icon: fetching ? "arrow.clockwise" : "checkmark.circle",
                                title: fetching ? "Fetching tickets\u{2026}" : model.isRaw && model.activeJQL == nil ? "Press Return to run the query"
                                : model.rows.isEmpty ? "No tickets" : "Nothing matches",
                                text: model.rows.isEmpty || fetching ? nil : "Change the chip, the search or the filters.") { EmptyView() }
    }

    private var list: some View {
        let groups = JiraTickets.groups(model.visible, by: model.filter.group), agents = JiraTickets.agents(writer.states())
        let ordered = groups.flatMap(\.tickets)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        if !group.title.isEmpty {
                            Text("\(group.title) \u{00B7} \(group.tickets.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                        }
                        ForEach(group.tickets) { ticket in
                            VStack(spacing: 0) {
                                JiraRow(ticket: ticket, model: model, agent: agents[ticket.key], selected: ticket.key == selected) {
                                    model.select(ticket.key)
                                    showsDetail = true
                                }
                                Divider().padding(.horizontal, Self.gutter)
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.gutter - 8)
                .padding(.bottom, 20)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1, in: ordered) }
            .onKeyPress(.downArrow) { step(1, in: ordered) }
            .onKeyPress(.return) {
                guard let selected else { return .ignored }
                model.openAgent(key: selected)
                return .handled
            }
            .onPasteCommand(of: [.plainText, .url]) { _ in
                NSPasteboard.general.string(forType: .string).map { _ = model.openAgent(typed: $0) }
            }
            .onChange(of: selected) { if let selected { proxy.scrollTo(selected) } }
        }
    }

    private func step(_ offset: Int, in tickets: [JiraTicket]) -> KeyPress.Result {
        model.select(JiraDetail.step(from: selected, offset: offset, in: tickets.map(\.key)))
        return .handled
    }
}

private struct JiraRow: View {
    let ticket: JiraTicket
    @ObservedObject var model: JiraPageModel
    let agent: AgentState?
    let selected: Bool
    let select: () -> Void
    @State private var hover: Task<Void, Never>?

    var body: some View {
        let prs = model.pullRequests[ticket.key] ?? []
        HStack(spacing: 8) {
            Circle().fill(JiraStyle.color(JiraTickets.stage(ticket))).frame(width: 7, height: 7).help(JiraTickets.stage(ticket).title)
            VStack(alignment: .leading, spacing: 2) {
                Text(facts).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(ticket.summary).lineLimit(2).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            JiraStatusPill(ticket: ticket)
            if let priority = ticket.priority { Text(priority).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
            if let pr = prs.first { PullRequestBadge(pr: pr, count: prs.count) { model.openLinkedPullRequest(pr) } }
            if let agent, let help = JiraStyle.agentHelp(agent) {
                Circle().fill(AgentList.color(AgentOverview.need(agent))).frame(width: 8, height: 8).help(help)
            }
            Button { model.openAgent(key: ticket.key) } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(agent == nil ? Color.secondary : Color.accentColor)
            .help(agent == nil ? "Open an agent for \(ticket.key)" : "Open the agent of \(ticket.key)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.openAgent(key: ticket.key) })
        .onHover(perform: prefetch)
        .contextMenu {
            statusItems
            Menu("Assign") {
                Button("Assign to Me") { model.assignToMe(ticket.key) }
                Button("Unassign") { model.assign(ticket.key, to: nil) }.disabled(ticket.assignee == nil)
                Button("Choose Person\u{2026}") { openPicker(assign: true) }
            }
            Divider()
            Button("Open Agent") { model.openAgent(key: ticket.key) }
            Button("Open in Jira") { model.browseURL(ticket.key).map { _ = NSWorkspace.shared.open($0) } }.disabled(model.site == nil)
            Button("Copy Key") { GitHubModel.copy(ticket.key) }
            Button("Copy Link") { model.browseURL(ticket.key).map { GitHubModel.copy($0.absoluteString) } }.disabled(model.site == nil)
            RemindMeMenu(title: ticket.summary, source: .jira(key: ticket.key))
            if !prs.isEmpty {
                Divider()
                ForEach(prs) { pr in Button("Open \(pr.repo) #\(String(pr.number))") { model.openLinkedPullRequest(pr) } }
            }
        }
        .help(ticket.key)
    }

    /// The moves Jira offered when the pointer rested on the row, or a way to ask for them.
    @ViewBuilder private var statusItems: some View {
        if let moves = model.transitions[ticket.key], !moves.isEmpty {
            Menu("Move to") {
                ForEach(moves) { move in
                    Button(move.name + (move.needsJira ? " (in Jira)" : !move.fields.isEmpty ? "\u{2026}" : "")) {
                        if move.fields.isEmpty, !move.needsJira { model.move(ticket.key, with: move) } else { openPicker(assign: false) }
                    }
                }
            }
        }
        Button("Change Status\u{2026}") { openPicker(assign: false) }
    }

    private func openPicker(assign: Bool) {
        select()
        if assign { model.assignPicker = ticket.key } else { model.statusPicker = ticket.key }
    }

    /// Fetches the ticket's moves once the pointer has rested on its row, so the context menu can list them.
    private func prefetch(_ inside: Bool) {
        hover?.cancel()
        guard inside else { return }
        hover = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { model.loadTransitions(ticket.key) }
        }
    }

    private var facts: String {
        [ticket.key, ticket.type, ticket.assignee, ticket.updated.map { "updated \(GitHubLogic.updatedText($0, now: Date()))" }]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

struct JiraStatusPill: View {
    let ticket: JiraTicket
    var chevron = false

    var body: some View {
        let color = JiraTickets.isBlocked(ticket) ? Color.red : JiraStyle.color(JiraTickets.stage(ticket))
        HStack(spacing: 3) {
            Text(ticket.status).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .fixedSize()
    }
}

private struct PullRequestBadge: View {
    let pr: GitHubPR
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label("#\(String(pr.number))" + (count > 1 ? " +\(String(count - 1))" : ""), systemImage: "arrow.triangle.pull")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("\(pr.repo) #\(pr.number) \(pr.title)")
    }
}

enum JiraStyle {
    static func color(_ stage: JiraStage) -> Color {
        switch stage {
        case .todo: return .secondary
        case .inProgress: return .accentColor
        case .inReview: return .purple
        case .done: return .green
        }
    }

    /// What the dot on a row says about the ticket's agent; nil while it is idle and has nothing new.
    static func agentHelp(_ agent: AgentState) -> String? {
        let need = AgentOverview.need(agent)
        return need == .idle ? nil : need.label
    }
}

/// Opens a ticket's agent from a pasted key or browse link, e.g. one a colleague sent.
private struct OpenTicketButton: View {
    @ObservedObject var model: JiraPageModel
    var compact = false
    @State private var showing = false
    @State private var text = ""

    var body: some View {
        Button { showing = true } label: {
            if compact { Image(systemName: "link") } else { Label("Open ticket\u{2026}", systemImage: "link") }
        }
        .fixedSize()
        .help("Open the agent of a ticket from its key or link")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open a ticket").font(.headline)
                TextField("QDLY-8332 or https://acme.atlassian.net/browse/QDLY-8332", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .onSubmit(open)
                Text(invalid ? "Type a Jira key like QDLY-8332 or paste a browse link." : "Opens the ticket\u{2019}s agent, made the first time.")
                    .font(.caption)
                    .foregroundStyle(invalid ? .red : .secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showing = false }.keyboardShortcut(.cancelAction)
                    Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(JiraLogic.issueKey(text) == nil)
                }
            }
            .padding(14)
            .frame(width: 388)
            .onAppear { text = NSPasteboard.general.string(forType: .string).flatMap { JiraLogic.issueKey($0) != nil ? $0 : nil } ?? "" }
        }
    }

    private var invalid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && JiraLogic.issueKey(text) == nil }

    private func open() {
        guard model.openAgent(typed: text) else { return }
        showing = false
        text = ""
    }
}

private struct JiraErrorBanner: View {
    let error: JiraError

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.message).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1))
    }
}
