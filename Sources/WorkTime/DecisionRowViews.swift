import SwiftUI

/// Which decision rows are open, which has the keyboard, and what ⌘Return does for each; kept while the list is open.
@MainActor
final class DecisionRowsModel: ObservableObject {
    static let shared = DecisionRowsModel()
    @Published private(set) var rows = DecisionExpansion()
    private var primaries: [String: () -> Void] = [:]

    func isExpanded(_ id: String) -> Bool { rows.isExpanded(id) }

    var focus: String? { rows.focus }

    func toggle(_ id: String) { withAnimation(.easeOut(duration: 0.15)) { rows.toggle(id) } }

    func move(_ step: Int, in ids: [String]) { rows.moveFocus(step, in: ids) }

    func activate() { withAnimation(.easeOut(duration: 0.15)) { rows.activate() } }

    func prune(to ids: [String]) {
        rows.prune(to: ids)
        primaries = primaries.filter { ids.contains($0.key) }
    }

    func register(_ id: String, primary: (() -> Void)?) { primaries[id] = primary }

    func runPrimary() { focus.flatMap { primaries[$0] }?() }
}

/// What a decision row says when it is opened: each section with its heading, and a long call cut to a few lines with "Show all".
struct DecisionSectionsView: View {
    let sections: [DecisionSection]
    @State private var all: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.heading).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if section.monospaced {
                        let (shown, hidden) = DecisionDetail.lines(section.text)
                        Text(verbatim: all.contains(section.id) ? section.text : shown).font(.caption.monospaced()).textSelection(.enabled)
                        if hidden > 0, !all.contains(section.id) { Button("Show all \(hidden + DecisionDetail.previewLines) lines") { all.insert(section.id) }.linkButtonStyle().font(.caption) }
                    } else {
                        Text(section.text).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Wraps a decision row: a click anywhere but its buttons opens or closes it, and the row shows when the keyboard is on it.
struct DecisionRowFrame<Content: View>: View {
    let id: String
    /// The agent that raised the decision; its spaces show on the row and it can be sent to another.
    var agent: String?
    var primary: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ObservedObject private var model = DecisionRowsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content()
            SpaceDecisionAccessory(agent: agent).padding(.leading, 26)
        }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(model.focus == id ? Color.white.opacity(0.07) : .clear))
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(id) }
            .spaceContextMenu(agent: agent)
            .onAppear { model.register(id, primary: primary) }
            .transition(.opacity)
    }
}

/// The small arrow that says a row can be opened.
struct DecisionChevron: View {
    let id: String
    @ObservedObject private var model = DecisionRowsModel.shared

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(model.isExpanded(id) ? 90 : 0))
            .frame(width: 14, height: 14)
    }
}

/// A drafted review in the notch bar: the pull request, what the reviewer recommends and why, the one click that posts it, and the whole
/// review when the row is opened.
struct ReviewDecisionRow: View {
    let draft: ReviewDraft
    let notice: AgentNotice
    let onOpen: () -> Void
    @ObservedObject private var model = DecisionRowsModel.shared
    @ObservedObject private var known = GitHubModel.shared

    private var id: String { DecisionIDs.review(draft.id) }

    var body: some View {
        let info = draft.target.map { ReviewPRInfo(known.knownPullRequest($0)) } ?? ReviewPRInfo()
        DecisionRowFrame(id: id, agent: notice.source.agent, primary: primary) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.orange).frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        ReviewHeader(draft: draft, info: info)
                        Spacer(minLength: 4)
                        DecisionChevron(id: id)
                    }
                    summary
                    ReviewActionBar(draft: draft, via: "notch", dismiss: { NoticeCenter.shared.dismissReview(draft) })
                    links
                    if model.isExpanded(id) { ReviewDetailView(draft: draft, info: info, agent: notice.source.title, date: notice.created) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var summary: some View {
        let reason = ReviewRows.reason(draft)
        if !reason.isEmpty, !model.isExpanded(id) { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        if let counts = ReviewRows.counts(draft) { Text(counts).font(.caption2).foregroundStyle(.tertiary) }
        if !model.isExpanded(id), let first = ReviewRows.firstComment(draft) {
            Text(verbatim: first).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
        }
    }

    private var links: some View {
        HStack(spacing: 10) {
            Button(model.isExpanded(id) ? "Hide the review" : "Read the review") { model.toggle(id) }
            if let target = draft.target {
                Button("Open in the app") {
                    onOpen()
                    AgentModel.openPullRequestLink?(target)
                }
                if let url = URL(string: target.url) { Button("Open on GitHub") { NSWorkspace.shared.open(url) } }
            }
        }
        .linkButtonStyle()
        .font(.caption)
    }

    private func primary() {
        Task { await NoticeCenter.shared.post(draft, ReviewRows.primary(draft), via: "notch") }
    }
}

/// The whole review: who drafted it, the pull request, its description, ticket and checks, the reasoning and the comments with their code.
struct ReviewDetailView: View {
    let draft: ReviewDraft
    let info: ReviewPRInfo
    let agent: String?
    let date: Date
    @ObservedObject private var details = ReviewDetailStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DecisionSectionsView(sections: DecisionDetail.review(draft: draft, info: info, detail: details.loaded[draft.pr]?.detail, agent: agent, date: date))
            ReviewCommentList(draft: draft, files: details.loaded[draft.pr]?.files, startsOpen: true)
        }
        .padding(.top, 4)
        .onAppear { details.load(draft) }
    }
}

/// Several drafted reviews of one notification as a compact table: one line per pull request with its verdict, reason and main click,
/// each opening into the whole review.
struct ReviewSetTable: View {
    let notice: AgentNotice
    let drafts: [ReviewDraft]
    let onOpen: () -> Void
    let dismiss: () -> Void
    @ObservedObject private var model = DecisionRowsModel.shared
    @ObservedObject private var notices = NoticeCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review ready: \(drafts.count) pull requests").fontWeight(.medium)
            ForEach(drafts) { draft in
                if model.isExpanded(DecisionIDs.review(draft.id)) {
                    ReviewDecisionRow(draft: draft, notice: notice, onOpen: onOpen)
                } else {
                    ReviewSetLine(draft: draft)
                }
            }
            HStack(spacing: 8) {
                if ReviewBoard.canApproveAll(drafts) {
                    Button("Approve all \(drafts.count)") { Task { await notices.approveAll(notice.id) } }.buttonStyle(.borderedProminent).tint(.green)
                }
                Button("Dismiss", action: dismiss).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.leading, 8)
        }
    }
}

/// One pull request of a set: verdict chip, name, reason and the main click on a line.
private struct ReviewSetLine: View {
    let draft: ReviewDraft
    @ObservedObject private var known = GitHubModel.shared
    @ObservedObject private var notices = NoticeCenter.shared

    private var id: String { DecisionIDs.review(draft.id) }

    var body: some View {
        let info = draft.target.map { ReviewPRInfo(known.knownPullRequest($0)) } ?? ReviewPRInfo()
        DecisionRowFrame(id: id, primary: { Task { await notices.post(draft, ReviewRows.primary(draft), via: "notch") } }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DecisionChip(text: draft.verdict.title, tone: ReviewRows.tone(draft.verdict))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ReviewRows.heading(draft, info: info)).lineLimit(1)
                    let reason = ReviewRows.reason(draft, limit: 90)
                    if !reason.isEmpty { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if notices.reviewWorking.contains(draft.id) {
                    ProgressView().controlSize(.small)
                } else if ReviewPostStore.shared.posted(draft.id)?.ok == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(ReviewRows.primaryTitle(draft)) { Task { await notices.post(draft, ReviewRows.primary(draft), via: "notch") } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                DecisionChevron(id: id)
            }
        }
    }
}
