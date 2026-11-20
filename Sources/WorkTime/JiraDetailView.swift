import AppKit
import SwiftUI

/// The ticket selected on the Jira page, on the right of the list: what the list already knows shows at once, the rest of the
/// issue fills in when it is fetched.
struct JiraDetailView: View {
    let key: String
    @ObservedObject var model: JiraPageModel
    let back: (() -> Void)?
    @ObservedObject private var agentStates = AgentStateWriter.shared
    @ObservedObject private var linkStore = LinkStore.shared

    private static let gutter: CGFloat = 20

    var body: some View {
        let state = model.details[key] ?? .loading
        let issue: JiraIssue? = { if case .loaded(let issue) = state { issue } else { nil } }()
        let ticket = model.ticket(key) ?? issue.map(JiraAgents.ticket)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(ticket: ticket, summary: issue?.summary ?? ticket?.summary)
                actions(title: issue?.summary ?? ticket?.summary ?? key)
                relatedAgents
                switch state {
                case .loading: skeleton
                case .failed(let error): failure(error)
                case .loaded(let issue): loaded(issue)
                }
            }
            .frame(maxWidth: GitHubLayout.readingWidth, alignment: .leading)
            .padding(.horizontal, Self.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private func header(ticket: JiraTicket?, summary: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let back {
                    Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("Back to the list")
                }
                Text([key, ticket?.type].compactMap { $0 }.joined(separator: " \u{00B7} ")).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if let summary, !summary.isEmpty { Text(summary).font(.system(size: 20, weight: .medium)) }
            HStack(spacing: 8) {
                if let ticket, !ticket.status.isEmpty { JiraStatusButton(key: key, ticket: ticket, model: model) }
                if let priority = ticket?.priority { Text(priority).font(.callout).foregroundStyle(.secondary) }
            }
        }
    }

    private func actions(title: String) -> some View {
        FlowLayout(spacing: 6) {
            Button("Open in Jira") { model.browseURL(key).map { _ = NSWorkspace.shared.open($0) } }.disabled(model.site == nil)
            Button("Open Agent") { model.openAgent(key: key) }
            Button("Copy Key") { GitHubModel.copy(key) }
            assignMenu
            RemindMeMenu(title: title, source: .jira(key: key)).fixedSize()
        }
        .controlSize(.small)
    }

    private var assignMenu: some View {
        Menu("Assign") {
            Button("Assign to Me") { model.assignToMe(key) }
            Button("Unassign") { model.assign(key, to: nil) }.disabled(model.ticket(key)?.assignee == nil)
            Button("Choose Person\u{2026}") { model.assignPicker = key }
        }
        .fixedSize()
        .popover(isPresented: Binding(get: { model.assignPicker == key }, set: { if !$0, model.assignPicker == key { model.assignPicker = nil } }),
                 arrowEdge: .bottom) {
            JiraPersonPicker(model: model, issueKey: key) { model.assign(key, to: $0) }
        }
    }

    @ViewBuilder private var relatedAgents: some View {
        let agents = JiraDetail.agents(for: key, from: agentStates.states(), links: linkStore.searchIndex)
        if !agents.isEmpty {
            section(agents.count == 1 ? "Agent" : "Agents (\(agents.count))") {
                ForEach(agents, id: \.key) { state in
                    Button { AgentHub.shared.show(state.key) } label: {
                        HStack(spacing: 8) {
                            let need = AgentOverview.need(state)
                            Circle().fill(AgentList.color(need)).frame(width: 8, height: 8).help(need.label)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(TicketGrouping.label(state)).fontWeight(.medium)
                                if state.title != TicketGrouping.label(state) {
                                    Text(state.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            if state.archived == true { Text("Earlier").font(.caption).foregroundStyle(.tertiary) }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(state.archived == true ? 0.7 : 1)
                }
            }
        }
    }

    private func loaded(_ issue: JiraIssue) -> some View {
        let comments = JiraDetail.recentComments(issue)
        return VStack(alignment: .leading, spacing: 18) {
            facts(issue)
            pullRequests
            JiraLinkedView(key: key, model: model)
            section("Description") { description(issue.description) }
            if !issue.links.isEmpty {
                section("Linked issues") {
                    ForEach(issue.links, id: \.key) { link in
                        Button { model.select(link.key) } label: {
                            HStack(spacing: 6) {
                                Text(link.relation).foregroundStyle(.secondary)
                                Text(link.key).fontWeight(.medium)
                                Text(link.summary).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                if !link.status.isEmpty { Text(link.status).font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            section(issue.commentTotal == 0 ? "Comments" : "Comments (\(issue.commentTotal))") {
                if comments.shown.isEmpty { Text("No comments.").foregroundStyle(.tertiary) }
                if comments.hidden > 0 { Text("\(comments.hidden) earlier in Jira").font(.caption).foregroundStyle(.tertiary) }
                ForEach(Array(comments.shown.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([comment.author, comment.created.map { GitHubLogic.updatedText($0, now: Date()) }].compactMap { $0 }
                            .joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary)
                        Text(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            section("Add a comment") { JiraCommentBox(key: key, model: model) }
            section("Log work") { JiraWorklogBox(key: key, model: model) }
        }
    }

    private func facts(_ issue: JiraIssue) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(JiraDetail.facts(issue, now: Date()), id: \.title) { fact in
                GridRow {
                    Text(fact.title).foregroundStyle(.secondary)
                    Text(fact.value)
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var pullRequests: some View {
        let prs = model.pullRequests[key] ?? []
        if !prs.isEmpty {
            section("Pull requests") {
                ForEach(prs) { pr in
                    Button { model.openLinkedPullRequest(pr) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
                            Text("\(pr.repo) #\(String(pr.number))").fontWeight(.medium)
                            Text(pr.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(pr.isDraft ? "draft" : pr.state.rawValue).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func description(_ text: String) -> some View {
        let blocks = JiraDetail.blocks(text)
        if blocks.isEmpty {
            Text("No description.").foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let text): Text(text)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}").foregroundStyle(.secondary)
                            Text(text)
                        }
                    }
                }
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach([120.0, 160.0, 90.0], id: \.self) { bar($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach([420.0, 380.0, 260.0], id: \.self) { bar($0) }
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Fetching \(key)\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ width: Double) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: width, height: 10)
    }

    private func failure(_ error: JiraError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            Button("Try Again") { model.loadDetail(key, force: true) }.controlSize(.small)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
