import SwiftUI

/// What became of the drafted reviews that were posted or tried, kept between runs of the app.
@MainActor
final class ReviewPostStore: ObservableObject {
    static let shared = ReviewPostStore()
    static let key = "reviewDraftPosted"

    @Published private(set) var book: ReviewPostedBook.Book

    init() { book = ReviewPostedBook.decode(AgentModel.defaults.data(forKey: Self.key)) }

    func posted(_ draft: String) -> ReviewPosted? { book[draft] }

    func record(_ posted: ReviewPosted, draft: String) {
        book = ReviewPostedBook.record(posted, draft: draft, in: book)
        AgentModel.defaults.set(ReviewPostedBook.encode(book), forKey: Self.key)
    }
}

/// The buttons that post a drafted review: they decide, when clicked, whether it can go with this click or needs the confirmation.
struct ReviewButtons: View {
    let draft: ReviewDraft
    @ObservedObject private var notices = NoticeCenter.shared
    let via: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                button(.approve, prominent: draft.verdict == .approve)
                if draft.problem(for: .requestChanges) == nil { button(.requestChanges, prominent: draft.verdict == .requestChanges) }
                if !draft.comments.isEmpty { button(.postComments, prominent: false) }
                if notices.reviewWorking.contains(draft.id) { ProgressView().controlSize(.small) }
            }
            ReviewWays(draft: draft, via: via)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func button(_ action: ReviewAction, prominent: Bool) -> some View {
        let title = Button(action.title) { Task { await notices.post(draft, action, via: via) } }
            .disabled(notices.reviewWorking.contains(draft.id) || notices.reviewWaiting.contains(draft.id))
            .help(GitHubActions.isReviewFromNotifications() ? "Posts the review with this click" : "Opens the confirmation with the review in it")
        if prominent { title.buttonStyle(.borderedProminent) } else { title.buttonStyle(.bordered) }
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
                Button("Cancel") { notices.cancelWaiting(draft) }.buttonStyle(.link).font(.caption)
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

/// A drafted review in a reply: what it says and the buttons that post it, or what became of it.
struct ReviewDraftCard: View {
    let draft: ReviewDraft
    @ObservedObject private var store = ReviewPostStore.shared
    @ObservedObject private var notices = NoticeCenter.shared
    @State private var showsComments = false

    private var posted: ReviewPosted? { store.posted(draft.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text("Review draft \u{00B7} \(draft.reference)").fontWeight(.medium)
                Text(draft.verdict.title.lowercased()).foregroundStyle(.secondary)
                if let sha = draft.sha { Text(ReviewApproval.short(sha)).font(.caption.monospaced()).foregroundStyle(.tertiary) }
            }
            if !draft.summary.isEmpty { Text(draft.summary).font(.callout).textSelection(.enabled) }
            if !draft.comments.isEmpty { commentList }
            if let posted, posted.ok {
                Label(posted.text, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
            } else {
                ReviewButtons(draft: draft, via: "chat")
                if let text = notices.reviewResults[draft.id] ?? posted?.text {
                    Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let target = draft.target {
                Button("Open pull request") { AgentModel.openPullRequestLink?(target) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    @ViewBuilder private var commentList: some View {
        Button(showsComments ? "Hide \(draft.comments.count) comments on lines" : "Show \(draft.comments.count) comments on lines") { showsComments.toggle() }
            .buttonStyle(.link)
            .font(.caption)
        if showsComments {
            ForEach(Array(draft.comments.enumerated()), id: \.offset) { _, comment in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: comment.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(comment.body).font(.callout).textSelection(.enabled)
                }
                .padding(.leading, 8)
            }
        }
    }
}
