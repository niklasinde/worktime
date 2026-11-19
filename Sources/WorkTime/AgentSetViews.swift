import AppKit
import SwiftUI

extension LinkedPR {
    init(pr: GitHubPR, checkout: String? = nil) {
        self.init(url: pr.url, repo: pr.repo, number: pr.number, title: pr.title, checkout: checkout)
    }
}

extension GitHubModel {
    /// A pull request WorkTime has fetched, from any of its lists.
    func pullRequest(url: String) -> GitHubPR? {
        prs.values.joined().first { $0.url == url } ?? watchedPRs.first { $0.url == url }
    }
}

extension TopicAgentStore {
    /// Adds pull requests to the agent, with their checkouts looked up, and shows it.
    func addAndShow(_ prs: [LinkedPR], to key: String) {
        Task { @MainActor in
            add(await Self.withCheckouts(prs), to: key)
            show(key)
        }
    }
}

/// The items for sending pull requests to an agent: a new one for them together, or one that exists.
struct AddToAgentMenu: View {
    let prs: [LinkedPR]
    @ObservedObject private var store = TopicAgentStore.shared

    var body: some View {
        Button(prs.count > 1 ? "New Agent for These \(prs.count)" : "New Agent for This Pull Request") { store.openSet(prs) }
        let linked = Set(AddToAgent.linkedAgents(of: prs, agents: store.visible.map(\.key), index: LinkStore.shared.searchIndex))
        let agents = store.visible.filter { linked.contains($0.key) }
        if !agents.isEmpty {
            Divider()
            ForEach(agents) { agent in
                Button(agent.name) { store.addAndShow(prs, to: agent.key) }
            }
        }
    }
}

/// A small mark on a pull request that is part of a set agent.
struct InSetBadge: View {
    let url: String
    @ObservedObject private var store = TopicAgentStore.shared

    var body: some View {
        if let set = PullRequestSets.set(containing: url, in: store.topics), !set.archived {
            Label("in set", systemImage: "square.stack.3d.up")
                .font(.caption2)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
                .help("Part of \u{201C}\(set.name)\u{201D}: opening it opens that agent")
        }
    }
}

/// The pull requests of an agent in its header: each with its state, a way to open it and take it out, and a way to add another.
struct AgentSetChips: View {
    let topic: TopicAgent
    @ObservedObject private var github = GitHubModel.shared
    @State private var adding = false
    @State private var link = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(topic.linked, id: \.url) { chip($0) }
                addButton
            }
        }
        .frame(maxWidth: 520)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func chip(_ linked: LinkedPR) -> some View {
        HStack(spacing: 4) {
            if let pr = github.pullRequest(url: linked.url) { PRStatusDot(pr: pr) }
            Button { GitHubModel.shared.showInWindow?(linked.target) } label: { Text(linked.shortLabel).font(.caption) }
                .buttonStyle(.plain)
                .help([linked.title, linked.url].compactMap { $0 }.joined(separator: "\n"))
            Button { TopicAgentStore.shared.remove(linked.url, from: topic.key) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Take it out of this agent; it opens its own agent again")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private var addButton: some View {
        Button { adding = true } label: { Image(systemName: "plus").font(.caption) }
            .buttonStyle(.borderless)
            .help("Add a pull request")
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a pull request").font(.headline)
                    TextField("Link or owner/repo#123", text: $link).textFieldStyle(.roundedBorder).frame(width: 280).onSubmit(add)
                    HStack {
                        Spacer()
                        Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(GitHubLink.pasted(link) == nil)
                    }
                }
                .padding(12)
            }
    }

    private func add() {
        guard let target = GitHubLink.pasted(link) else { return }
        TopicAgentStore.shared.addAndShow([LinkedPR(target: target)], to: topic.key)
        link = ""
        adding = false
    }
}
