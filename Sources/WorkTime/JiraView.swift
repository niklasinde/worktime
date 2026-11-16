import AppKit
import SwiftUI

/// The Jira page: the user's tickets by tab, each with the one agent of its ticket, laid out like the GitHub page.
struct JiraView: View {
    @ObservedObject var model: JiraPageModel
    @ObservedObject private var writer = AgentStateWriter.shared
    @ObservedObject private var topics = TopicAgentStore.shared
    @State private var selected: String?
    @FocusState private var focused: Bool

    private static let gutter: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, model.hasData { JiraErrorBanner(error: error) }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(8).background(.quaternary)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            model.linkPullRequests()
            Task { await model.refresh() }
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
                Text(JiraTickets.header(count: model.visible.count, tab: model.tab, capped: model.isCapped))
                    .font(.system(size: 22, weight: .medium))
                    .padding(.top, 8)
                statusChips.padding(.top, 6)
                ViewThatFits(in: .horizontal) {
                    searchRow(compact: false)
                    searchRow(compact: true)
                }
                .controlSize(.small)
                .padding(.top, 10)
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
            SearchField(text: $model.filter.query).frame(minWidth: compact ? nil : 150)
            filtersMenu
            OpenTicketButton(model: model, compact: compact)
        }
    }

    private var filtersMenu: some View {
        let options = model.options
        return Menu {
            choice("Project", $model.filter.project, options.projects, all: "All projects")
            choice("Type", $model.filter.type, options.types, all: "All types")
            choice("Status", $model.filter.statusName, options.statuses, all: "All statuses")
            choice("Priority", $model.filter.priority, options.priorities, all: "All priorities")
            choice("Assignee", $model.filter.assignee, ["Unassigned"] + options.assignees, all: "Anyone")
            Divider()
            Button("Open These in Jira") {
                model.site.flatMap { JiraTickets.navigatorURL(site: $0, jql: JiraTickets.jql(model.tab, model.filter)) }.map { _ = NSWorkspace.shared.open($0) }
            }
            .disabled(model.site == nil)
            Button("Reset Filters") { model.filter = model.filter.withoutRefinements }.disabled(model.filter.refinements == 0)
        } label: {
            Label(model.filter.refinements == 0 ? "Filters" : "Filters \u{00B7} \(model.filter.refinements)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project, type, status, priority and assignee")
    }

    private func choice(_ title: String, _ selection: Binding<String?>, _ values: [String], all: String) -> some View {
        Picker(title, selection: selection) {
            Text(all).tag(String?.none)
            ForEach(values, id: \.self) { Text($0).tag(String?.some($0)) }
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
            GitHubEmptyState(icon: model.refreshing && !model.hasData ? "arrow.clockwise" : "checkmark.circle",
                             title: model.refreshing && !model.hasData ? "Fetching tickets\u{2026}"
                             : model.rows.isEmpty ? "No tickets" : "Nothing matches",
                             text: model.rows.isEmpty ? nil : "Change the chip, the search or the filters.") { EmptyView() }
        } else {
            list
        }
    }

    private var list: some View {
        let visible = model.visible, agents = JiraTickets.agents(writer.states())
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { ticket in
                        VStack(spacing: 0) {
                            JiraRow(ticket: ticket, model: model, agent: agents[ticket.key], selected: ticket.key == selected) { selected = ticket.key }
                            Divider().padding(.horizontal, Self.gutter)
                        }
                    }
                }
                .padding(.horizontal, Self.gutter - 8)
                .padding(.bottom, 20)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1, in: visible) }
            .onKeyPress(.downArrow) { step(1, in: visible) }
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
        let index = selected.flatMap { key in tickets.firstIndex { $0.key == key } }
        let next = index.map { min(max($0 + offset, 0), tickets.count - 1) } ?? (offset > 0 ? 0 : tickets.count - 1)
        selected = tickets[next].key
        return .handled
    }
}

private struct JiraRow: View {
    let ticket: JiraTicket
    @ObservedObject var model: JiraPageModel
    let agent: AgentState?
    let selected: Bool
    let select: () -> Void

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
        .contextMenu {
            Button("Open Agent") { model.openAgent(key: ticket.key) }
            Button("Open in Jira") { model.browseURL(ticket.key).map { _ = NSWorkspace.shared.open($0) } }.disabled(model.site == nil)
            Button("Copy Key") { GitHubModel.copy(ticket.key) }
            Button("Copy Link") { model.browseURL(ticket.key).map { GitHubModel.copy($0.absoluteString) } }.disabled(model.site == nil)
            if !prs.isEmpty {
                Divider()
                ForEach(prs) { pr in Button("Open \(pr.repo) #\(String(pr.number))") { model.openLinkedPullRequest(pr) } }
            }
        }
        .help(ticket.key)
    }

    private var facts: String {
        [ticket.key, ticket.type, ticket.assignee, ticket.updated.map { "updated \(GitHubLogic.updatedText($0, now: Date()))" }]
            .compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

private struct JiraStatusPill: View {
    let ticket: JiraTicket

    var body: some View {
        let color = JiraTickets.isBlocked(ticket) ? Color.red : JiraStyle.color(JiraTickets.stage(ticket))
        Text(ticket.status)
            .font(.caption)
            .lineLimit(1)
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
