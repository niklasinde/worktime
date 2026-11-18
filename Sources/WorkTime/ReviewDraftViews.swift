import SwiftUI

/// What became of the drafted reviews that were posted or tried, kept between runs of the app.
@MainActor
final class ReviewPostStore: ObservableObject {
    static let shared = ReviewPostStore()
    static let key = "reviewDraftPosted"
    static let dismissedKey = "reviewDraftDismissed"

    @Published private(set) var book: ReviewPostedBook.Book

    private(set) var dismissed: ReviewDismissedBook.Book

    init() {
        book = ReviewPostedBook.decode(AgentModel.defaults.data(forKey: Self.key))
        dismissed = ReviewDismissedBook.decode(AgentModel.defaults.data(forKey: Self.dismissedKey))
    }

    func posted(_ draft: String) -> ReviewPosted? { book[draft] }

    func isDismissed(_ draft: String) -> Bool { dismissed[draft] != nil }

    func dismiss(_ draft: String) {
        dismissed = ReviewDismissedBook.record(draft, date: Date(), in: dismissed)
        AgentModel.defaults.set(ReviewDismissedBook.encode(dismissed), forKey: Self.dismissedKey)
    }

    func record(_ posted: ReviewPosted, draft: String) {
        book = ReviewPostedBook.record(posted, draft: draft, in: book)
        AgentModel.defaults.set(ReviewPostedBook.encode(book), forKey: Self.key)
    }
}

/// What one click on a drafted review does and what came of the last one: the main button named for the review's own verdict, the
/// other ways in a menu, a line saying exactly what is posted, and then posting, posted, or failed with a way to try again.
struct ReviewActionBar: View {
    let draft: ReviewDraft
    let via: String
    var dismiss: (() -> Void)?
    @ObservedObject private var notices = NoticeCenter.shared
    @ObservedObject private var store = ReviewPostStore.shared

    private var excluded: Set<Int> { notices.reviewExcluded[draft.id] ?? [] }

    private var state: ReviewRows.State {
        ReviewRows.state(working: notices.reviewWorking.contains(draft.id), waiting: notices.reviewWaiting.contains(draft.id),
                         posted: store.posted(draft.id), result: notices.reviewResults[draft.id])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .posted(let text):
                Label(text, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            case .posting:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Posting\u{2026}").font(.caption).foregroundStyle(.secondary) }
            case .failed(let reason, let action):
                Text(reason).font(.caption).foregroundStyle(.red).lineLimit(4)
                HStack(spacing: 8) {
                    Button("Retry") { Task { await notices.post(draft, action, via: via) } }.buttonStyle(.bordered)
                    dismissButton
                }
                .controlSize(.small)
            case .waiting, .ready:
                if state == .ready { ready }
                ReviewWays(draft: draft, via: via)
            }
        }
    }

    @ViewBuilder private var ready: some View {
        let primary = ReviewRows.primary(draft)
        HStack(spacing: 8) {
            Button(ReviewRows.primaryTitle(draft, excluded: excluded)) { post(primary) }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .help(GitHubActions.isReviewFromNotifications() ? "Posts the review with this click" : "Opens the confirmation with the review in it")
            more
            dismissButton
        }
        .controlSize(.small)
        Text(ReviewRows.preview(draft, action: primary, excluded: excluded)).font(.caption2).foregroundStyle(.tertiary)
        if let note = notices.reviewResults[draft.id] { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
    }

    @ViewBuilder private var dismissButton: some View {
        if let dismiss {
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Dismiss this review without posting it")
        }
    }

    private var more: some View {
        Menu("More") {
            ForEach(ReviewRows.alternatives(draft)) { alternative in
                Button(alternative.note.map { "\(alternative.title) \u{2014} \($0)" } ?? alternative.title) { run(alternative) }
            }
            if let dismiss {
                Divider()
                Button("Dismiss", action: dismiss)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var tint: Color {
        switch ReviewRows.tone(draft.verdict) {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .gray
        }
    }

    private func post(_ action: ReviewAction, mode: ReviewPostMode = .normal) { Task { await notices.post(draft, action, via: via, mode: mode) } }

    private func run(_ alternative: ReviewRows.Alternative) {
        switch alternative.kind {
        case .action(let action): post(action, mode: action == .approve && draft.verdict != .approve ? .anyway : .normal)
        case .summaryOnly: Task { await notices.post(ReviewRows.summaryOnly(draft), .postComments, via: via) }
        }
    }
}

/// What can be clicked after a click did not post: the reason, and the ways on, or the wait for the checks with its Cancel. Every refusal
/// leaves at least the confirmation to open.
struct ReviewWays: View {
    let draft: ReviewDraft
    let via: String
    @ObservedObject private var notices = NoticeCenter.shared

    var body: some View {
        if notices.reviewWaiting.contains(draft.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the checks to pass, then approving").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { notices.cancelWaiting(draft) }.linkButtonStyle().font(.caption)
            }
        } else if let refusal = notices.reviewRefusals[draft.id], !notices.reviewWorking.contains(draft.id) {
            HStack(spacing: 8) {
                ForEach(refusal.choices, id: \.self) { choice in
                    if choice == refusal.choices.first {
                        Button(choice.title) { run(choice, refusal) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(choice.title) { run(choice, refusal) }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
        }
    }

    private func run(_ choice: ReviewChoice, _ refusal: ReviewRefusal) {
        switch choice {
        case .approveAnyway: Task { await notices.post(draft, .approve, via: via, mode: .anyway) }
        case .approveWhenGreen: notices.approveWhenGreen(draft, via: via)
        case .commentInstead: Task { await notices.post(draft, .postComments, via: via) }
        case .openSheet: Task { await notices.post(draft, refusal.action, via: via, mode: .sheet) }
        }
    }
}

/// A drafted review in a reply: what it recommends and why, the comments with the code they are about, and the one click that posts it.
struct ReviewDraftCard: View {
    let draft: ReviewDraft
    @ObservedObject private var details = ReviewDetailStore.shared
    @ObservedObject private var known = GitHubModel.shared

    var body: some View {
        let info = draft.target.map { ReviewPRInfo(known.knownPullRequest($0)) } ?? ReviewPRInfo()
        VStack(alignment: .leading, spacing: 8) {
            ReviewHeader(draft: draft, info: info)
            if !draft.summary.isEmpty { Text(ReviewDraft.untagged(draft.summary)).font(.callout).textSelection(.enabled) }
            ReviewCommentList(draft: draft, files: details.loaded[draft.pr]?.files)
            ReviewActionBar(draft: draft, via: "chat")
            if let target = draft.target {
                Button("Open pull request") { AgentModel.openPullRequestLink?(target) }.linkButtonStyle().font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .onAppear { details.load(draft) }
    }
}

/// The verdict as a coloured chip.
struct DecisionChip: View {
    let text: String
    let tone: ReviewRows.Tone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .positive: return .green
        case .negative: return .red
        case .neutral: return .gray
        }
    }
}

/// The pull request's name, who wrote it, how big it is and where its checks are, and what the reviewer recommends.
struct ReviewHeader: View {
    let draft: ReviewDraft
    let info: ReviewPRInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DecisionChip(text: draft.verdict.title, tone: ReviewRows.tone(draft.verdict))
                Text(ReviewRows.heading(draft, info: info)).fontWeight(.medium).lineLimit(2)
            }
            let meta = ReviewRows.meta(info)
            if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// The comments on lines: each with its place, its text and, once the pull request's patch is known, the code around the line, and a box
/// that takes it out of what is posted.
struct ReviewCommentList: View {
    let draft: ReviewDraft
    let files: [DiffFile]?
    @ObservedObject private var notices = NoticeCenter.shared
    @State private var shown: Bool

    init(draft: ReviewDraft, files: [DiffFile]?, startsOpen: Bool = false) {
        self.draft = draft
        self.files = files
        _shown = State(initialValue: startsOpen)
    }

    var body: some View {
        if !draft.comments.isEmpty {
            Button(shown ? "Hide \(draft.comments.count) comments on lines" : "Show \(draft.comments.count) comments on lines") { shown.toggle() }
                .linkButtonStyle()
                .font(.caption)
            if shown {
                ForEach(Array(draft.comments.enumerated()), id: \.offset) { index, comment in
                    let out = notices.reviewExcluded[draft.id]?.contains(index) == true
                    HStack(alignment: .top, spacing: 6) {
                        Toggle("", isOn: Binding(get: { !out }, set: { _ in notices.toggleExcluded(draft.id, index) })).labelsHidden().toggleStyle(.checkbox)
                            .help(out ? "Left out of what is posted" : "Posted with the review")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: comment.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(ReviewDraft.untagged(comment.body)).font(.callout).textSelection(.enabled)
                            if let excerpt = excerpt(comment) { Text(verbatim: excerpt).font(.caption2.monospaced()).foregroundStyle(.secondary).padding(4).background(Color.primary.opacity(0.06)) }
                        }
                        .opacity(out ? 0.45 : 1)
                    }
                }
            }
        }
    }

    private func excerpt(_ comment: ReviewDraft.Comment) -> String? {
        files?.first { $0.path == comment.path }?.patch.flatMap { ReviewHunks.excerpt(patch: $0, line: comment.line) }
    }
}
