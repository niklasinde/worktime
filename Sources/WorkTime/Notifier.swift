import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let meetingCategory = "meeting-started"
    private static let recordAction = "record"
    private static let meetingIdentifier = "meeting-started"
    private static let endedCategory = "meeting-ended"
    private static let stopAction = "stop"
    private static let keepAction = "keep"
    private static let meetingKey = "meeting"
    private static let reviewCategory = "automation-review"
    private static let reviewAgentAction = "review-agent"
    private static let reviewApproveAction = "review-approve"
    private static let reviewChangesAction = "review-changes"
    private static let reviewDismissAction = "review-dismiss"

    private let onRecord: @MainActor @Sendable () async -> Void
    private let onOpen: @MainActor @Sendable (URL) -> Void
    private let onStop: @MainActor @Sendable () async -> Void
    private let onKeepRecording: @MainActor @Sendable () -> Void
    private let center = UNUserNotificationCenter.current()

    init(onRecord: @escaping @MainActor @Sendable () async -> Void, onOpen: @escaping @MainActor @Sendable (URL) -> Void,
         onStop: @escaping @MainActor @Sendable () async -> Void, onKeepRecording: @escaping @MainActor @Sendable () -> Void) {
        self.onRecord = onRecord
        self.onOpen = onOpen
        self.onStop = onStop
        self.onKeepRecording = onKeepRecording
        super.init()
        center.delegate = self
        Self.applyCategories()
    }

    private static func fixedCategories() -> [UNNotificationCategory] {
        let record = UNNotificationAction(identifier: recordAction, title: "Record", options: [])
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop", options: [])
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep recording", options: [])
        let allow = UNNotificationAction(identifier: AgentAttention.allowAction, title: "Allow once", options: [])
        let allowSession = UNNotificationAction(identifier: AgentAttention.allowSessionAction, title: "Allow for this session", options: [])
        let deny = UNNotificationAction(identifier: AgentAttention.denyAction, title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: AgentAttention.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Answer the agent")
        let stopAgent = UNNotificationAction(identifier: AgentAttention.stopAction, title: "Stop", options: [.destructive])
        let reviewAgent = UNNotificationAction(identifier: reviewAgentAction, title: "Open review", options: [.foreground])
        let reviewApprove = UNNotificationAction(identifier: reviewApproveAction, title: "Approve\u{2026}", options: [.foreground])
        let reviewChanges = UNNotificationAction(identifier: reviewChangesAction, title: "Request changes\u{2026}", options: [.foreground])
        let reviewDismiss = UNNotificationAction(identifier: reviewDismissAction, title: "Dismiss", options: [])
        return [
            UNNotificationCategory(identifier: reviewCategory, actions: [reviewApprove, reviewChanges, reviewAgent, reviewDismiss], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: meetingCategory, actions: [record], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: endedCategory, actions: [stop, keep], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: AgentAttention.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: AgentAttention.sessionApprovalCategory, actions: [allow, allowSession, deny], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: AgentAttention.questionCategory, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: AgentAttention.handoffCategory, actions: [stopAgent], intentIdentifiers: [], options: []),
        ]
    }

    /// The buttons of an automation's question are its own names, so each pair of names is a category of its own, added as they are needed.
    private final class AskCategories: @unchecked Sendable {
        static let shared = AskCategories()
        private let lock = NSLock()
        private var known: [String: NoticeAsk] = [:]

        /// Whether the question's buttons were not known yet.
        func insert(_ ask: NoticeAsk) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return known.updateValue(ask, forKey: AutomationAsks.category(ask)) == nil
        }

        var categories: [UNNotificationCategory] {
            lock.lock()
            defer { lock.unlock() }
            return known.values.map { ask in
                let yes = UNNotificationAction(identifier: AutomationAsks.yesAction, title: ask.yes, options: [])
                let no = UNNotificationAction(identifier: AutomationAsks.noAction, title: ask.no, options: [])
                let open = UNNotificationAction(identifier: AutomationAsks.openAction, title: "Open", options: [.foreground])
                return UNNotificationCategory(identifier: AutomationAsks.category(ask), actions: [yes, no, open], intentIdentifiers: [], options: [])
            }
        }
    }

    private static func applyCategories() {
        UNUserNotificationCenter.current().setNotificationCategories(Set(fixedCategories() + AskCategories.shared.categories))
    }

    /// Makes the buttons of questions that are still waiting known to the system, as after a restart.
    static func register(asks: [NoticeAsk]) {
        var added = false
        for ask in asks where AskCategories.shared.insert(ask) { added = true }
        if added { applyCategories() }
    }

    func postMeetingStarted(appName: String?) {
        let content = content(title: "Meeting started \u{2014} record it?", body: MeetingApps.notificationBody(appName: appName))
        content.categoryIdentifier = Self.meetingCategory
        post(content, identifier: Self.meetingIdentifier)
    }

    func postMeetingEnded() {
        let minutes = Int(AutoStop.silenceLimit / 60)
        let content = content(title: "Meeting ended \u{2014} stop recording?",
                              body: "The recording stops by itself after \(minutes) minutes of silence.")
        content.categoryIdentifier = Self.endedCategory
        post(content, identifier: Self.endedCategory)
    }

    func postProcessed(title: String, body: String, meeting: URL) {
        let content = content(title: title, body: body)
        content.userInfo = [Self.meetingKey: meeting.path]
        post(content, identifier: UUID().uuidString)
    }

    /// Says Main handed a pull request's agent a prompt, so it is not missed while that agent works out of sight.
    static func postAgentMessage(title: String, body: String, agent: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(AgentAttention.handoffLimit))
        if let agent {
            content.userInfo = [AgentAttention.agentKey: agent, AgentAttention.requestKey: ""]
            content.categoryIdentifier = AgentAttention.handoffCategory
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// An agent stopped on a permission prompt; Allow once, Allow for this session (where offered) and Deny answer it without opening the app, a click opens the agent.
    static func postApproval(agent: String, permission: String, text: (title: String, body: String), sessionOffered: Bool = false) {
        post(text, category: AgentAttention.approvalCategory(sessionOffered: sessionOffered), agent: agent, request: permission,
             identifier: AgentAttention.approvalIdentifier(agent: agent, permission: permission))
    }

    /// An agent finished a turn on a question; Reply sends what is typed to it as the next prompt.
    static func postQuestion(agent: String, text: (title: String, body: String)) {
        post(text, category: AgentAttention.questionCategory, agent: agent, request: nil, identifier: AgentAttention.questionIdentifier(agent: agent))
    }

    private static func post(_ text: (title: String, body: String), category: String, agent: String, request: String?, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.categoryIdentifier = category
        content.interruptionLevel = .timeSensitive
        content.userInfo = [AgentAttention.agentKey: agent, AgentAttention.requestKey: request ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func withdraw(identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// An agent's notification, at once or with a calendar trigger at its time so it shows even while the app is busy or quit.
    static func postNotice(_ notice: AgentNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.source.title ?? ""
        content.body = notice.body ?? ""
        content.sound = .default
        content.userInfo = [NoticeLogic.userInfoKey: notice.id]
        if let ask = notice.ask {
            register(asks: [ask])
            content.categoryIdentifier = AutomationAsks.category(ask)
        } else if NoticeLogic.isReview(notice) {
            content.categoryIdentifier = reviewCategory
        }
        if notice.urgency == .high { content.interruptionLevel = .timeSensitive }
        let trigger = notice.at.map {
            UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0),
                                          repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: NoticeLogic.identifier(notice.id), content: content, trigger: trigger))
    }

    /// A reminder's system notification at its due time, so it shows even while the app is quit.
    static func postReminderAlarm(_ reminder: Reminder, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.subtitle = reminder.source?.label ?? ""
        content.sound = .default
        content.userInfo = [ReminderLogic.userInfoKey: reminder.id]
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ReminderLogic.alarmIdentifier(reminder.id), content: content, trigger: trigger))
    }

    static func withdrawReminderAlarm(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [ReminderLogic.alarmIdentifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [ReminderLogic.alarmIdentifier(id)])
    }

    /// A meeting brief shortly before the meeting; a click opens the brief in the notch bar.
    static func postBrief(title: String, body: String, key: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [MeetingBriefLogic.userInfoKey: key]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "brief:" + key, content: content, trigger: nil))
    }

    static func withdrawNotice(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [NoticeLogic.identifier(id)])
        center.removeDeliveredNotifications(withIdentifiers: [NoticeLogic.identifier(id)])
    }

    func withdrawMeetingStarted() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingIdentifier])
    }

    func withdrawMeetingEnded() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.endedCategory])
    }

    private func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        if let agent = content.userInfo[AgentAttention.agentKey] as? String {
            let request = (content.userInfo[AgentAttention.requestKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            await AgentAttentionCenter.shared.respond(agent: agent, request: request, action: action,
                                                      text: (response as? UNTextInputNotificationResponse)?.userText)
            return
        }
        if let id = content.userInfo[NoticeLogic.userInfoKey] as? String {
            switch action {
            case UNNotificationDefaultActionIdentifier, AutomationAsks.openAction: await NoticeCenter.shared.open(id)
            case AutomationAsks.yesAction: await NoticeCenter.shared.answer(id, yes: true)
            case AutomationAsks.noAction: await NoticeCenter.shared.answer(id, yes: false)
            case Self.reviewApproveAction: await NoticeCenter.shared.review(id, requestChanges: false)
            case Self.reviewChangesAction: await NoticeCenter.shared.review(id, requestChanges: true)
            case Self.reviewAgentAction: await NoticeCenter.shared.openAgent(id)
            case Self.reviewDismissAction: await NoticeCenter.shared.dismiss(id)
            default: break
            }
            return
        }
        if let id = content.userInfo[ReminderLogic.userInfoKey] as? String {
            if action == UNNotificationDefaultActionIdentifier { await TodoModel.shared.openFromNotification(id) }
            return
        }
        if content.userInfo[MeetingBriefLogic.userInfoKey] != nil {
            if action == UNNotificationDefaultActionIdentifier { await MeetingBriefModel.shared.show() }
            return
        }
        if let path = content.userInfo[Self.meetingKey] as? String {
            if action == UNNotificationDefaultActionIdentifier { await onOpen(URL(fileURLWithPath: path)) }
            return
        }
        switch (content.categoryIdentifier, action) {
        case (Self.meetingCategory, Self.recordAction), (Self.meetingCategory, UNNotificationDefaultActionIdentifier):
            await onRecord()
        case (Self.endedCategory, Self.stopAction):
            await onStop()
        case (Self.endedCategory, Self.keepAction):
            await onKeepRecording()
        default:
            break
        }
    }
}
