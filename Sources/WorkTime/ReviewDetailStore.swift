import Foundation

/// What a review row needs from GitHub to be read in full: the pull request's description and checks and the patches of its files,
/// fetched once when a row is opened and kept.
@MainActor
final class ReviewDetailStore: ObservableObject {
    static let shared = ReviewDetailStore()

    struct Loaded {
        var detail: GitHubPRDetail?
        var files: [DiffFile]?
    }

    @Published private(set) var loaded: [String: Loaded] = [:]
    private var loading: Set<String> = []

    func load(_ draft: ReviewDraft) {
        guard let link = draft.target, loaded[draft.pr] == nil, loading.insert(draft.pr).inserted else { return }
        let cli = GitHubLogic.findCLI(), repo = link.repo, number = link.number
        Task {
            let (result, files) = await Task.detached {
                (GitHubClient.fetchDetail(cli: cli, repo: repo, number: number), GitHubClient.fetchPullFiles(cli: cli, repo: repo, number: number))
            }.value
            var detail: GitHubPRDetail?
            if case .success(let fetched) = result { detail = fetched.detail }
            loaded[draft.pr] = Loaded(detail: detail, files: files)
            loading.remove(draft.pr)
        }
    }
}
