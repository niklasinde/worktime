import AppKit
import SwiftUI

/// The tickets and pull requests the session has to do with, under the work map: its own, its branch's, and those its transcript mentions.
struct SessionLinksView: View {
    @ObservedObject var model: AgentModel
    @ObservedObject private var github = GitHubModel.shared
    @State private var branchRefs: [SessionRef] = []
    @State private var expanded = false

    var body: some View {
        let refs = model.related.ordered(pinned: model.relatedPinned + branchRefs)
        if !refs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header(count: refs.count)
                let shown = SessionLinkRows.visible(refs, expanded: expanded)
                ScrollView {
                    VStack(spacing: 0) { ForEach(shown, id: \.id) { SessionLinkRow(ref: $0, model: model) } }
                }
                .frame(maxHeight: expanded ? 230 : nil)
                .fixedSize(horizontal: false, vertical: !expanded)
                let hidden = SessionLinkRows.hidden(refs, expanded: expanded)
                if hidden > 0 || expanded && refs.count > SessionLinkRows.collapsed {
                    Button(expanded ? "Show less" : "Show \(hidden) more") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(AgentWorkMap.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                Divider().overlay(AgentWorkMap.line.opacity(0.2)).padding(.top, 4)
            }
            .task(id: lookupKey) { await findBranch() }
        } else {
            Color.clear.frame(height: 0).task(id: lookupKey) { await findBranch() }
        }
    }

    private var lookupKey: String { "\(model.folder)|\(model.busy)|\(github.prs.values.reduce(0) { $0 + $1.count })" }

    private func header(count: Int) -> some View {
        HStack {
            Text("Related")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The branch the session's folder is on: its ticket, and its pull request when the GitHub page has it.
    private func findBranch() async {
        let folder = model.folder
        guard let branch = await GitBranch.current(in: folder) else {
            if !branchRefs.isEmpty { branchRefs = [] }
            return
        }
        var refs = SessionLinks.references(in: branch, projects: model.relatedProjects)
        let cached = GitHubLogic.unique(github.prs) + github.watchedPRs
        let onBranch = cached.filter { github.store?.githubHeadBranch($0.url) == branch }
        let name = (folder as NSString).lastPathComponent
        let ours = onBranch.filter { $0.repo.hasSuffix("/" + name) }
        refs += (ours.isEmpty ? onBranch : ours).compactMap { GitHubLink.pullRequest(at: $0.url) }.map(SessionRef.init)
        if refs != branchRefs { branchRefs = refs }
    }
}

/// The branch a folder is on, read with git off the main thread.
enum GitBranch {
    static let ignored: Set<String> = ["HEAD", "main", "master", "develop"]

    static func current(in folder: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder, "rev-parse", "--abbrev-ref", "HEAD"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, !ignored.contains(name) else { return nil }
            return name
        }.value
    }
}

private struct SessionLinkRow: View {
    let ref: SessionRef
    @ObservedObject var model: AgentModel
    @ObservedObject private var github = GitHubModel.shared
    @ObservedObject private var jira = JiraPageModel.shared
    @State private var hovering = false

    private var pullRequest: GitHubPR? {
        guard let url = ref.target?.url else { return nil }
        return (GitHubLogic.unique(github.prs) + github.watchedPRs).first { $0.url == url }
    }

    private var ticket: JiraTicket? { ref.key.flatMap { jira.ticket($0) } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                mark.frame(width: 18)
                Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).fixedSize()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu { menu }
    }

    @ViewBuilder private var mark: some View {
        if let pullRequest {
            StatusMark(pr: pullRequest).scaleEffect(0.8)
        } else if ref.target != nil {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            Image(systemName: "checklist").font(.system(size: 12)).foregroundStyle(statusColor)
        }
    }

    private var statusColor: Color {
        switch ticket?.category {
        case .done?: .green
        case .inProgress?: .blue
        default: .secondary
        }
    }

    private var label: String { ref.target.map { "#\($0.number)" } ?? ref.key ?? "" }

    private var title: String {
        if let pullRequest { return pullRequest.isDraft ? "Draft \u{00B7} " + pullRequest.title : pullRequest.title }
        return ticket?.summary ?? ""
    }

    private var detail: String? {
        if let target = ref.target { return target.repo.split(separator: "/").last.map(String.init) }
        return ticket?.status
    }

    private var helpText: String { [label, title, ref.target?.repo].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") }

    private var remindTitle: String { title.isEmpty ? label : "\(label) \(title)" }

    private var browserURL: URL? {
        if let target = ref.target { return URL(string: target.url) }
        return ref.key.flatMap { key in JiraModel.shared.site.flatMap { JiraLogic.browseURL(site: $0, key: key) } }
    }

    private var linkedPR: LinkedPR? { ref.target.map { LinkedPR(target: $0, title: pullRequest?.title) } }

    private func open() {
        if let target = ref.target { AgentModel.openPullRequestLink?(target) } else if let key = ref.key { AgentModel.openJiraLink?(key) }
    }

    @ViewBuilder private var menu: some View {
        Button("Open in WorkTime", action: open)
        if let url = browserURL {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
        }
        Divider()
        if let linkedPR {
            if let topic = model.topic {
                Button("Add to This Agent") { TopicAgentStore.shared.addAndShow([linkedPR], to: topic.key) }
            }
            Menu("Add to Agent") { AddToAgentMenu(prs: [linkedPR]) }
        }
        if let target = ref.target {
            RemindMeMenu(title: remindTitle, source: .pullRequest(target))
        } else if let key = ref.key {
            RemindMeMenu(title: remindTitle, source: .jira(key: key, summary: ticket?.summary))
        }
        if let url = browserURL {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }
}
