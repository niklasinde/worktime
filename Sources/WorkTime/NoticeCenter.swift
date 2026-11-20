import AppKit
import UserNotifications

/// The notifications agents send through `notify`: shown or scheduled with the system, kept in `notifications.json` and listed
/// in the notch bar until the user opens or dismisses them.
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()
    static let grace: TimeInterval = 2
    static let lookupBatch = 20
    @Published private(set) var notices: [AgentNotice] = []
    /// The drafted reviews being posted now, and what became of the last click on each, for the rows that have buttons for them.
    @Published private(set) var reviewWorking: Set<String> = []
    @Published private(set) var reviewResults: [String: String] = [:]
    /// What a refused click leaves to click instead, and the approvals waiting for their checks, by draft.
    @Published private(set) var reviewRefusals: [String: ReviewRefusal] = [:]
    @Published private(set) var reviewWaiting: Set<String> = []
    /// The comments of a drafted review the user took out of what is posted, by draft and comment number.
    @Published private(set) var reviewExcluded: [String: Set<Int>] = [:]
    private var recent: [AgentNotice] = []
    private var resolvingClosed = false
    private var file: URL?
    private var timer: Timer?

    var pending: [AgentNotice] { NoticeLogic.pending(notices) }
    var waiting: [AgentNotice] { NoticeLogic.waiting(notices) }
    /// What waits for the user's answer.
    var decisions: [AgentNotice] { Decisions.waiting(notices) }

    func start(file: URL = AppPaths.notices) {
        self.file = file
        let saved = ReviewBoard.consolidated(NoticeLogic.decode(try? Data(contentsOf: file)))
        notices = saved.notices
        saved.removed.forEach { Notifier.withdrawNotice($0) }
        Notifier.register(asks: notices.compactMap(\.ask))
        notices.forEach(keepOnScreen)
        fireDue()
        Task { await resolveClosedPullRequests() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
    }

    func handle(_ request: NoticeRequest) -> NoticeReply {
        func reply(_ ok: Bool, _ notice: String?, _ message: String) -> NoticeReply {
            NoticeReply(id: request.id, ok: ok, notice: notice, message: message)
        }
        let now = Date()
        guard abs(now.timeIntervalSince(request.created)) <= AgentInbox.staleAfter else { return reply(false, nil, "The request is too old.") }
        switch request.action {
        case .cancel:
            guard let id = request.cancel else { return reply(false, nil, "id is required.") }
            if let problem = NoticeLogic.cancelProblem(id, in: notices, by: request.source) { return reply(false, id, problem) }
            dismiss(id)
            return reply(true, id, "Cancelled the notification \(id).")
        case .notify:
            guard var notice = request.notice, !notice.title.isEmpty, notice.title.count <= NoticeLogic.titleLimit else {
                return reply(false, nil, "The notification has no usable title.")
            }
            notice.source = request.source
            notice.source.title = request.source.label(titles: titles())
            recent.removeAll { now.timeIntervalSince($0.created) >= NoticeLogic.collapseWindow }
            var message = notice.at == nil ? "Shown to the user." : "Scheduled."
            switch NoticeLogic.admit(notice, existing: notices, recent: recent, now: now) {
            case .reject(let problem): return reply(false, nil, problem)
            case .collapse(let id): return reply(true, id, "The same notification was shown moments ago, so it was not shown again.")
            case .replace(let id):
                notice.id = id
                notices.removeAll { $0.id == id }
                message = "Updated the notification that was already there."
            case .add: break
            }
            recent.append(notice)
            notices.append(notice)
            Notifier.postNotice(notice)
            keepOnScreen(notice)
            save()
            return reply(true, notice.id, message)
        }
    }

    /// Opens what the notification links to (or the agent that sent it) and takes it off the list.
    func open(_ id: String) {
        guard let notice = notices.first(where: { $0.id == id }) else { return }
        if notice.ask == nil, notice.reviews == nil { dismiss(id) }
        switch notice.link.flatMap(NoticeLogic.link) {
        case .pullRequest(let target)?: AgentModel.openPullRequestLink?(target)
        case .agent(let key)?: AgentHub.shared.show(key)
        case .jira(let key)?:
            if let url = JiraModel.shared.site.flatMap({ JiraLogic.browseURL(site: $0, key: key) }) { NSWorkspace.shared.open(url) }
        case .web(let url)?: NSWorkspace.shared.open(url)
        case nil:
            if let source = notice.link.flatMap({ ReminderSource.parse($0) }) { TodoModel.shared.open(source) }
            else if let agent = notice.source.agent { AgentHub.shared.show(agent) } else { TodoModel.shared.reveal() }
        }
    }

    /// The user's answer to an automation's question, from the notification's buttons or the notch bar: takes the question off the list,
    /// completes its reminder, notes the answer on the automation, and with yes starts the agent it names, without opening the app.
    func answer(_ id: String, yes: Bool) {
        guard let notice = notices.first(where: { $0.id == id }), let ask = notice.ask else { return }
        dismiss(id)
        if let reminder = ask.reminder { TodoModel.shared.complete(reminder) }
        RoutineStore.shared.record(AskAnswer(title: notice.title, yes: yes, date: Date()), routine: ask.routine)
        guard yes else { return }
        Task {
            let reply = await AgentInboxWatcher.send(ask.prompt, to: ask.agent, pullRequests: ask.pullRequests, ticket: ask.ticket, pr: ask.pullRequest, origin: ask.origin, links: ask.links)
            if reply.status == .rejected { Notifier.postAgentMessage(title: "Could not start: \(notice.title)", body: reply.message) }
        }
    }

    /// The reminder of a question was completed in the app: the user dealt with it, so the question goes without starting anything.
    func resolveAsk(reminder: String) {
        for notice in notices where notice.ask?.reminder == reminder { dismiss(notice.id) }
    }

    /// How many questions of the automation wait for an answer.
    func waitingAsks(routine: String) -> Int { notices.filter { $0.ask?.routine == routine }.count }

    /// Shows the agent whose run sent the notification.
    func openAgent(_ id: String) {
        guard let notice = notices.first(where: { $0.id == id }), let agent = notice.source.agent else { return }
        dismiss(id)
        AgentHub.shared.show(agent)
    }

    /// Opens the pull request a review notification is about and asks the page's own confirmation to approve it or request changes:
    /// nothing is sent until the user confirms there.
    func review(_ id: String, requestChanges: Bool) {
        guard let notice = notices.first(where: { $0.id == id }), NoticeLogic.isReview(notice),
              case .pullRequest(let target)? = notice.link.flatMap(NoticeLogic.link) else { return }
        open(id)
        GitHubModel.shared.beginReview(of: target, requestChanges: requestChanges)
    }


    // MARK: Drafted reviews

    /// A notification for the reviews an agent drafted and did not post, with buttons that post them; one for the same drafts is updated.
    func addReview(_ drafts: [ReviewDraft], agent: String, agentTitle: String) {
        let open = ReviewDismissedBook.remaining(drafts, in: ReviewPostStore.shared.dismissed).filter { ReviewPostStore.shared.posted($0.id)?.ok != true }
        guard !open.isEmpty else { return }
        let now = Date()
        var notice = ReviewNotices.notice(drafts: open, agent: agent, agentTitle: agentTitle, now: now)
        if case .replace(let id) = NoticeLogic.admit(notice, existing: notices, recent: [], now: now) {
            notice.id = id
            notices.removeAll { $0.id == id }
        }
        let board = ReviewBoard.supersede(notices, by: open)
        for old in notices.filter({ board.removed.contains($0.id) }) {
            Notifier.withdrawNotice(old.id)
            DecisionKeeper.shared.release(NoticeLogic.identifier(old.id))
        }
        for old in notices.flatMap({ $0.reviews ?? [] }) where open.contains(where: { $0.pr == old.pr && $0.id != old.id }) {
            reviewResults[old.id] = nil
            reviewRefusals[old.id] = nil
            reviewExcluded[old.id] = nil
        }
        notices = board.notices
        notices.append(notice)
        Notifier.postNotice(notice)
        keepOnScreen(notice)
        save()
    }

    /// Puts a drafted review aside for good: it is not posted and does not come back unless the agent drafts one for a new commit.
    func dismissReview(_ draft: ReviewDraft) {
        ReviewPostStore.shared.dismiss(draft.id)
        removeReview(draft)
    }

    private func removeReview(_ draft: ReviewDraft) {
        GitHubModel.shared.cancelGreenWait(draft.id)
        reviewWaiting.remove(draft.id)
        reviewResults[draft.id] = nil
        reviewRefusals[draft.id] = nil
        reviewExcluded[draft.id] = nil
        guard let notice = notices.first(where: { $0.reviews?.contains { $0.id == draft.id } == true }) else { return }
        guard let updated = ReviewNotices.afterDismissing(notice, draft: draft), let index = notices.firstIndex(where: { $0.id == notice.id }) else {
            return dismissUnanswered(notice.id)
        }
        replace(updated, at: index, show: false)
    }

    /// Takes away what is about a pull request that was merged or closed: its drafted reviews, questions and review notices, and the
    /// reminders agents raised for it. A draft is not remembered as dismissed, so a new one after a reopening shows again.
    func resolveClosedPullRequests() async {
        guard !resolvingClosed else { return }
        resolvingClosed = true
        defer { resolvingClosed = false }
        let urls = ClosedPullRequests.urls(notices: notices, reminders: TodoModel.shared.reminders)
        guard !urls.isEmpty else { return }
        var states = GitHubModel.shared.cachedStates
        let unknown = urls.filter { states[$0] == nil || states[$0] == .open }
        let cli = GitHubLogic.findCLI()
        for start in stride(from: 0, to: unknown.count, by: Self.lookupBatch) {
            let batch = Array(unknown[start..<min(start + Self.lookupBatch, unknown.count)])
            guard let found = await Task.detached(priority: .utility, operation: { GitHubClient.fetchLookup(cli: cli, urls: batch) }).value else { continue }
            states.merge(ClosedPullRequests.states(of: found)) { _, new in new }
        }
        let resolution = ClosedPullRequests.resolution(notices: notices, reminders: TodoModel.shared.reminders, states: states)
        resolution.drafts.forEach(removeReview)
        for id in resolution.notices {
            if let reminder = notices.first(where: { $0.id == id })?.ask?.reminder { TodoModel.shared.complete(reminder) }
            dismiss(id)
        }
        resolution.reminders.forEach(TodoModel.shared.complete)
    }

    /// A button of a notification about one drafted review.
    func postFromNotification(_ id: String, _ action: ReviewAction) async {
        guard let drafts = notices.first(where: { $0.id == id })?.reviews, drafts.count == 1 else { return }
        await post(drafts[0], action, via: "notification")
    }

    /// The user's click on a button of a drafted review, from a notification, the notch bar or a chat. Whether it posts at once or opens
    /// the page's confirmation is decided by what the pull request is like now.
    @discardableResult
    func post(_ draft: ReviewDraft, _ action: ReviewAction, via: String, mode: ReviewPostMode = .normal) async -> ReviewOutcome {
        guard !ReviewPostStore.shared.isDismissed(draft.id) else { return .failed("The review was dismissed.") }
        reviewWorking.insert(draft.id)
        reviewResults[draft.id] = nil
        reviewRefusals[draft.id] = nil
        let sent = ReviewRows.applying(draft, excluded: reviewExcluded[draft.id] ?? [])
        let outcome = await GitHubModel.shared.postReview(sent, action, via: via, mode: mode)
        reviewWorking.remove(draft.id)
        if case .confirming = outcome { reviewRefusals[draft.id] = GitHubModel.shared.reviewRefusal(for: draft.id) }
        finish(draft, action, via: via, outcome)
        return outcome
    }

    private func finish(_ draft: ReviewDraft, _ action: ReviewAction, via: String, _ outcome: ReviewOutcome) {
        reviewResults[draft.id] = outcome.text
        switch outcome {
        case .posted(let text): ReviewPostStore.shared.record(ReviewPosted(action: action, text: text, ok: true, date: Date()), draft: draft.id)
        case .failed(let text): ReviewPostStore.shared.record(ReviewPosted(action: action, text: text, ok: false, date: Date()), draft: draft.id)
        case .confirming, .opened: break
        }
        settle(draft, outcome: outcome, loud: via == "notification")
    }

    /// Takes a comment of a drafted review out of what is posted, or puts it back.
    func toggleExcluded(_ draft: String, _ index: Int) {
        var out = reviewExcluded[draft] ?? []
        if out.contains(index) { out.remove(index) } else { out.insert(index) }
        reviewExcluded[draft] = out.isEmpty ? nil : out
    }

    /// "Approve when green": waits for the checks and approves only if the pull request is still fine to approve with one click.
    func approveWhenGreen(_ draft: ReviewDraft, via: String) {
        reviewRefusals[draft.id] = nil
        reviewResults[draft.id] = nil
        reviewWaiting.insert(draft.id)
        GitHubModel.shared.approveWhenGreen(draft, via: via) { [weak self] outcome in
            guard let self else { return }
            self.reviewWaiting.remove(draft.id)
            self.finish(draft, .approve, via: via, outcome)
        }
    }

    func cancelWaiting(_ draft: ReviewDraft) {
        GitHubModel.shared.cancelGreenWait(draft.id)
        reviewWaiting.remove(draft.id)
        reviewResults[draft.id] = "Stopped waiting. Nothing was posted."
    }

    /// What a click did to the notification that holds the draft: the posted draft goes, and with the last one the notification
    /// becomes the result; a failure stays with its reason.
    private func settle(_ draft: ReviewDraft, outcome: ReviewOutcome, loud: Bool) {
        guard let index = notices.firstIndex(where: { $0.reviews?.contains { $0.id == draft.id } == true }) else { return }
        let notice = notices[index]
        switch outcome {
        case .posted(let text):
            let updated = ReviewNotices.afterPosting(notice, draft: draft, text: text)
            if !loud, updated.reviews == nil { return dismiss(notice.id) }
            replace(updated, at: index, show: loud)
            if updated.reviews == nil { moveToResolved(notice.id) }
        case .failed(let text):
            replace(ReviewNotices.afterFailure(notice, text: text), at: index, show: loud)
        case .confirming(let text), .opened(let text):
            replace(ReviewNotices.afterFailure(notice, text: "Not posted: " + text), at: index, show: loud)
        }
    }

    /// A review that was posted stays in the list for a moment, saying so, and then moves to Resolved.
    private func moveToResolved(_ id: String, after seconds: UInt64 = 20) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, let notice = self.notices.first(where: { $0.id == id }), notice.reviews == nil, !Decisions.needsAnswer(notice) else { return }
            TodoModel.shared.resolveWithoutAnswer(notice)
            self.dismiss(id)
        }
    }

    private func replace(_ notice: AgentNotice, at index: Int, show: Bool) {
        notices[index] = notice
        if !Decisions.needsAnswer(notice) { DecisionKeeper.shared.release(NoticeLogic.identifier(notice.id)) }
        if show { Notifier.postNotice(notice) }
        save()
    }

    /// The first step of approving a set at once: every pull request is looked at again, and when each is fine to approve the user
    /// is asked once more, naming them. Otherwise the notification says which one is not and why.
    func approveAll(_ id: String) async {
        guard let notice = notices.first(where: { $0.id == id }), let drafts = notice.reviews, !drafts.isEmpty else { return }
        let problems = await GitHubModel.shared.approvalProblems(drafts)
        guard problems.isEmpty else {
            if let index = notices.firstIndex(where: { $0.id == id }) {
                replace(ReviewNotices.afterFailure(notice, text: "Not approved in one go:\n" + problems.joined(separator: "\n")), at: index, show: true)
            }
            return
        }
        Notifier.postReviewConfirmation(notice: id, title: ReviewNotices.confirmTitle(drafts), body: ReviewNotices.confirmBody(drafts))
    }

    /// The second step: each pull request is checked once more, as the commit may have changed meanwhile, and the ones that pass are approved.
    func confirmApproveAll(_ id: String) async {
        Notifier.withdrawReviewConfirmation(id)
        guard let notice = notices.first(where: { $0.id == id }), let drafts = notice.reviews, !drafts.isEmpty else { return }
        drafts.forEach { reviewWorking.insert($0.id) }
        let results = await GitHubModel.shared.approveAll(drafts)
        drafts.forEach { reviewWorking.remove($0.id) }
        for (draft, outcome) in results {
            reviewResults[draft.id] = outcome.text
            if outcome.posted { ReviewPostStore.shared.record(ReviewPosted(action: .approve, text: outcome.text, ok: true, date: Date()), draft: draft.id) }
        }
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        replace(ReviewNotices.afterApproving(notices[index], results: results), at: index, show: true)
    }

    func cancelApproveAll(_ id: String) { Notifier.withdrawReviewConfirmation(id) }

    /// The cross on a decision: it is put aside without an answer, and what it was about stays in Resolved.
    func dismissUnanswered(_ id: String) {
        if let notice = notices.first(where: { $0.id == id }), Decisions.needsAnswer(notice) { TodoModel.shared.resolveWithoutAnswer(notice) }
        dismiss(id)
    }

    /// A decision's notification comes back, quietly, if macOS sweeps it away before it is answered.
    private func keepOnScreen(_ notice: AgentNotice) {
        guard Decisions.needsAnswer(notice) else { return }
        let id = notice.id
        DecisionKeeper.shared.keep(NoticeLogic.identifier(id)) { [weak self] in
            guard let current = self?.notices.first(where: { $0.id == id }) else { return }
            Notifier.postNotice(current, quiet: true)
        }
    }

    /// Takes a notification off the list, and a scheduled one off the system's schedule too.
    func dismiss(_ id: String) {
        notices.removeAll { $0.id == id }
        Notifier.withdrawNotice(id)
        save()
    }

    /// Marks scheduled notifications whose time came as shown, or as missed when far behind; posts those the system has not.
    private func fireDue() {
        let due = NoticeLogic.due(notices, now: Date().addingTimeInterval(-Self.grace))
        guard !due.fire.isEmpty || !due.missed.isEmpty else { return }
        for index in notices.indices {
            if due.fire.contains(notices[index].id) { notices[index].state = .shown }
            if due.missed.contains(notices[index].id) { notices[index].state = .missed }
        }
        save()
        let fired = notices.filter { due.fire.contains($0.id) }
        Task {
            let delivered = Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
            for notice in fired where !delivered.contains(NoticeLogic.identifier(notice.id)) {
                var now = notice
                now.at = nil
                Notifier.postNotice(now)
            }
        }
    }

    /// The agents' titles by key, to name who sent something.
    func titles() -> [String: String] {
        Dictionary(AgentStateWriter.shared.states().map { ($0.key, $0.title) } + RoutineStore.shared.titles.map { ($0.key, $0.value) }) { first, _ in first }
    }

    private func save() {
        guard let file else { return }
        let data = NoticeLogic.encode(notices)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    #if DEBUG
    func showSample(_ notices: [AgentNotice]) { self.notices = notices }
    #endif
}
