import Foundation

/// A due date: a day for an all-day reminder, else a time that also gets a system notification.
struct ReminderDue: Codable, Equatable, Sendable {
    var date: Date
    var allDay = false
}

enum ReminderPriority: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high

    /// From EventKit's scale, as the one-time import reads it: 1 is high, 5 medium, 9 low, 0 none.
    init(eventKit: Int) {
        switch eventKit {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

/// Where a reminder came from: a pull request, a Jira ticket, a Slack message, a meeting or a web page.
struct ReminderSource: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case githubPR = "github_pr", jira, slack, meeting, url
    }

    var kind: Kind
    /// `owner/repo#7`, a Jira key, a Slack message link, a meeting's id or a web address.
    var reference: String
    var title: String?

    var label: String { title ?? reference }

    var icon: String {
        switch kind {
        case .githubPR: "arrow.triangle.pull"
        case .jira: "checklist"
        case .slack: "bubble.left.fill"
        case .meeting: "person.2.fill"
        case .url: "link"
        }
    }

    static func pullRequest(_ target: GitHubLink.Target) -> ReminderSource {
        let reference = "\(target.repo)#\(target.number)"
        return ReminderSource(kind: .githubPR, reference: reference, title: reference)
    }

    static func jira(key: String, summary: String? = nil) -> ReminderSource {
        ReminderSource(kind: .jira, reference: key, title: summary.map { "\(key) \($0)" } ?? key)
    }

    static func meeting(id: Int64, title: String? = nil) -> ReminderSource {
        ReminderSource(kind: .meeting, reference: String(id), title: title ?? "Meeting")
    }

    static func slack(link: URL, place: String? = nil) -> ReminderSource {
        ReminderSource(kind: .slack, reference: link.absoluteString, title: place.map { "Slack \($0)" } ?? "Slack message")
    }

    /// The source a link names: `owner/repo#7` or a pull request page, a Jira key or ticket address, a Slack message link,
    /// `meeting:<id>`, or another https address.
    static func parse(_ text: String, jiraSite: String? = nil) -> ReminderSource? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = text.wholeMatch(of: #/meeting:([0-9]{1,18})/#).flatMap({ Int64($0.1) }) { return .meeting(id: id) }
        if let target = GitHubLink.pasted(text) { return .pullRequest(target) }
        if SlackLogic.threadLink(text) != nil, let link = URL(string: text) { return .slack(link: link) }
        if !text.contains("://") { return JiraLogic.issueKey(text).map { .jira(key: $0) } }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host == jiraSite?.lowercased() || host.hasSuffix(".atlassian.net"), let key = JiraLogic.issueKey(text) { return .jira(key: key) }
        return ReminderSource(kind: .url, reference: url.absoluteString, title: host)
    }

    /// The address that shows the source in a browser, where it has one; a pull request, meeting or Slack message opens in the app first.
    func url(jiraSite: String?) -> URL? {
        switch kind {
        case .githubPR: GitHubLink.pasted(reference).flatMap { URL(string: $0.url) }
        case .jira: jiraSite.flatMap { JiraLogic.browseURL(site: $0, key: reference) }
        case .slack, .url: URL(string: reference)
        case .meeting: nil
        }
    }
}

struct Reminder: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var notes: String?
    var due: ReminderDue?
    var priority = ReminderPriority.none
    var created: Date
    var completed: Date?
    var source: ReminderSource?
    /// The agent that added it, when one did.
    var addedBy: String?

    var isOpen: Bool { completed == nil }
}

/// The reminders WorkTime keeps itself, in `reminders.json`.
struct ReminderBook: Codable, Equatable, Sendable {
    static let keepCompleted: TimeInterval = 30 * 86_400
    static let fileName = "reminders.json"
    static let unreadableName = "reminders.unreadable.json"

    var reminders: [Reminder] = []

    var open: [Reminder] { ReminderLogic.ordered(reminders.filter(\.isOpen)) }

    func reminder(_ id: String) -> Reminder? { reminders.first { $0.id == id } }

    /// Adds the reminder under a new short id and returns it.
    @discardableResult
    mutating func add(_ reminder: Reminder) -> Reminder {
        var saved = reminder
        saved.id = Self.newID(avoiding: Set(reminders.map(\.id)))
        reminders.append(saved)
        return saved
    }

    @discardableResult
    mutating func update(_ id: String, _ change: (inout Reminder) -> Void) -> Bool {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return false }
        change(&reminders[index])
        return true
    }

    @discardableResult
    mutating func complete(_ id: String, now: Date) -> Bool {
        update(id) { $0.completed = $0.completed ?? now }
    }

    mutating func delete(_ id: String) { reminders.removeAll { $0.id == id } }

    mutating func prune(now: Date) {
        reminders.removeAll { reminder in reminder.completed.map { now.timeIntervalSince($0) > Self.keepCompleted } ?? false }
    }

    static func newID(avoiding taken: Set<String>) -> String {
        while true {
            let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            if !taken.contains(id) { return id }
        }
    }

    // MARK: File

    /// The book in the file; a missing file is an empty book, an unreadable one is kept aside as `reminders.unreadable.json`.
    static func load(from file: URL) -> ReminderBook {
        guard let data = try? Data(contentsOf: file) else { return ReminderBook() }
        if let book = AgentInbox.decode(ReminderBook.self, from: data) { return book }
        let aside = file.deletingLastPathComponent().appendingPathComponent(unreadableName)
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
        return ReminderBook()
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentInbox.encode(self).write(to: file, options: .atomic)
    }
}
