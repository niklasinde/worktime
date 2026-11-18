import Foundation

/// What a `github` message carries: the fields the server sends for a webhook delivery, any of them missing.
struct GitHubEvent: Equatable, Decodable {
    var event: String?
    var action: String?
    var repo: String?
    var sender: String?
    var deliveryID: String?
    var number: Int?
    var title: String?
    var htmlURL: String?
    var state: String?
    var merged: Bool?
    var draft: Bool?

    enum CodingKeys: String, CodingKey {
        case event, action, repo, sender, number, title, state, merged, draft
        case deliveryID = "delivery_id", htmlURL = "html_url"
    }

    init(event: String? = nil, action: String? = nil, repo: String? = nil, number: Int? = nil, htmlURL: String? = nil,
         merged: Bool? = nil) {
        (self.event, self.action, self.repo, self.number, self.htmlURL, self.merged) = (event, action, repo, number, htmlURL, merged)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try? values.decodeIfPresent(String.self, forKey: .event)
        action = try? values.decodeIfPresent(String.self, forKey: .action)
        repo = try? values.decodeIfPresent(String.self, forKey: .repo)
        sender = try? values.decodeIfPresent(String.self, forKey: .sender)
        deliveryID = try? values.decodeIfPresent(String.self, forKey: .deliveryID)
        number = try? values.decodeIfPresent(Int.self, forKey: .number)
        title = try? values.decodeIfPresent(String.self, forKey: .title)
        htmlURL = try? values.decodeIfPresent(String.self, forKey: .htmlURL)
        state = try? values.decodeIfPresent(String.self, forKey: .state)
        merged = try? values.decodeIfPresent(Bool.self, forKey: .merged)
        draft = try? values.decodeIfPresent(Bool.self, forKey: .draft)
    }

    var isClosing: Bool { event == "pull_request" && action == "closed" }

    /// The address of the pull request the event is about, from its repository and number or else from its link.
    var pullRequestURL: String? {
        if let repo, let number, let target = GitHubLink.pullRequest(at: "https://github.com/\(repo)/pull/\(number)") { return target.url }
        guard var parts = htmlURL.flatMap(URLComponents.init(string:)) else { return nil }
        parts.fragment = nil
        parts.query = nil
        return parts.string.flatMap(GitHubLink.pullRequest(at:))?.url
    }
}

/// What the stream's settings let through, in groups the settings page offers.
enum GitHubEventKind: String, CaseIterable {
    case pullRequests, reviews, issueComments, checks

    var title: String {
        switch self {
        case .pullRequests: "Pull requests"
        case .reviews: "Reviews and review comments"
        case .issueComments: "Comments"
        case .checks: "Checks"
        }
    }

    var events: [String] {
        switch self {
        case .pullRequests: ["pull_request"]
        case .reviews: ["pull_request_review", "pull_request_review_comment"]
        case .issueComments: ["issue_comment"]
        case .checks: ["check_run", "check_suite", "workflow_run", "status"]
        }
    }

    static func kind(of event: String) -> GitHubEventKind? { allCases.first { $0.events.contains(event) } }
}

struct GitHubEventSettings: Equatable {
    static let enabledKey = "githubEventsEnabled"
    static let urlKey = "githubEventsURL"
    static let reposKey = "githubEventsRepos"
    static let kindsKey = "githubEventsKinds"
    static let streamMinutesKey = "githubEventsStreamMinutes"
    static let fallbackMinutesKey = "githubEventsFallbackMinutes"
    static let downSecondsKey = "githubEventsDownSeconds"
    static let backoffCapKey = "githubEventsBackoffCap"

    static let defaultURL = "https://devops.indepower.se/api/github_events/stream"
    static let streamMinuteChoices = [0, 5, 10, 30, 60]
    static let fallbackMinuteChoices = [0, 1, 5, 10, 15, 30, 60]
    static let downSecondChoices = [30, 60, 120, 300]
    static let backoffCapChoices = [30, 60, 120, 300]

    var enabled = false
    var url = defaultURL
    /// Full repository names; none means every repository.
    var repos: [String] = []
    var kinds = Set(GitHubEventKind.allCases)
    /// Minutes between fetches while the stream is up; 0 for none.
    var streamMinutes = 10
    /// Minutes between fetches while it is down; 0 for the one under Refresh every.
    var fallbackMinutes = 0
    var downSeconds = 60
    var backoffCap = 60

    init() {}

    init(_ defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        url = defaults.string(forKey: Self.urlKey) ?? Self.defaultURL
        repos = Self.parseRepos(defaults.string(forKey: Self.reposKey) ?? "")
        kinds = defaults.stringArray(forKey: Self.kindsKey).map { Set($0.compactMap(GitHubEventKind.init(rawValue:))) } ?? kinds
        streamMinutes = Self.choice(defaults, Self.streamMinutesKey, Self.streamMinuteChoices, default: streamMinutes)
        fallbackMinutes = Self.choice(defaults, Self.fallbackMinutesKey, Self.fallbackMinuteChoices, default: fallbackMinutes)
        downSeconds = Self.choice(defaults, Self.downSecondsKey, Self.downSecondChoices, default: downSeconds)
        backoffCap = Self.choice(defaults, Self.backoffCapKey, Self.backoffCapChoices, default: backoffCap)
    }

    func save(_ defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(url, forKey: Self.urlKey)
        defaults.set(repos.joined(separator: ", "), forKey: Self.reposKey)
        defaults.set(kinds.map(\.rawValue).sorted(), forKey: Self.kindsKey)
        defaults.set(streamMinutes, forKey: Self.streamMinutesKey)
        defaults.set(fallbackMinutes, forKey: Self.fallbackMinutesKey)
        defaults.set(downSeconds, forKey: Self.downSecondsKey)
        defaults.set(backoffCap, forKey: Self.backoffCapKey)
    }

    private static func choice(_ defaults: UserDefaults, _ key: String, _ allowed: [Int], default value: Int) -> Int {
        defaults.object(forKey: key) == nil || !allowed.contains(defaults.integer(forKey: key)) ? value : defaults.integer(forKey: key)
    }

    static func parseRepos(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init).filter { $0.contains("/") }
    }

    func follows(repo: String?) -> Bool {
        repos.isEmpty || repo.map { name in repos.contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? false
    }

    func allows(event: String?) -> Bool { event.flatMap(GitHubEventKind.kind(of:)).map(kinds.contains) ?? false }

    /// The address to open: the base with `repos` and `events` set from the settings. Nil when it is not an http(s) address or
    /// no event type is chosen.
    var streamURL: URL? {
        guard !kinds.isEmpty, var parts = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased()), parts.host?.isEmpty == false else { return nil }
        var query = (parts.queryItems ?? []).filter { $0.name != "repos" && $0.name != "events" }
        if !repos.isEmpty { query.append(URLQueryItem(name: "repos", value: repos.joined(separator: ","))) }
        let events = GitHubEventKind.allCases.filter(kinds.contains).flatMap(\.events)
        query.append(URLQueryItem(name: "events", value: events.joined(separator: ",")))
        parts.queryItems = query
        return parts.url
    }

    func request(token: String, lastEventID: String?) -> URLRequest? {
        guard let url = streamURL else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        return request
    }
}

enum GitHubStreamOutcome: Equatable {
    case connected, wrongToken, noServerToken, tooManyStreams, failed(String)

    init(status: Int) {
        switch status {
        case 200: self = .connected
        case 401: self = .wrongToken
        case 503: self = .noServerToken
        case 429: self = .tooManyStreams
        default: self = .failed("HTTP \(status)")
        }
    }

    /// Whether trying again soon cannot help until the settings change.
    var isRejection: Bool { self == .wrongToken || self == .noServerToken }

    var message: String {
        switch self {
        case .connected: "Connected"
        case .wrongToken: "Wrong token"
        case .noServerToken: "Server has no token set"
        case .tooManyStreams: "Too many streams open"
        case .failed(let reason): reason
        }
    }
}

enum GitHubStreamStatus: Equatable {
    case off
    case connecting
    case connected
    case reconnecting(seconds: Int, reason: String?)
    case rejected(GitHubStreamOutcome)

    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting\u{2026}"
        case .connected: "Connected"
        case .reconnecting(let seconds, _): "Reconnecting in \(seconds) s"
        case .rejected(let outcome): outcome.message
        }
    }
}

/// What a webhook event makes the app do.
struct GitHubEventAction: Equatable {
    var url: String
    var closing: Bool
}

enum GitHubEventLogic {
    static let retryAfterRejection: TimeInterval = 300
    static let healthyAfter: TimeInterval = 30
    static let debounce: TimeInterval = 2
    static let tick: TimeInterval = 15

    /// Seconds to wait before the next connection after `attempt` failed ones: 1 s doubling up to `cap`, spread by `jitter` (0 to 1)
    /// within a quarter either way, never above the cap.
    static func backoff(attempt: Int, cap: TimeInterval, jitter: Double) -> TimeInterval {
        let base = min(cap, pow(2, Double(min(max(attempt, 0), 16))))
        return min(cap, base * (0.75 + 0.5 * min(max(jitter, 0), 1)))
    }

    /// The number of failed attempts in a row after a connection that lasted `connectedFor` seconds (nil when it never opened).
    static func attempts(after previous: Int, connectedFor: TimeInterval?) -> Int {
        (connectedFor ?? 0) >= healthyAfter ? 0 : previous + 1
    }

    static func delay(after outcome: GitHubStreamOutcome, attempt: Int, cap: TimeInterval, jitter: Double) -> TimeInterval {
        outcome.isRejection ? retryAfterRejection : backoff(attempt: attempt, cap: cap, jitter: jitter)
    }

    /// The pull request to refresh for an event: one the settings let through, about a pull request the app tracks.
    static func action(for event: GitHubEvent, settings: GitHubEventSettings, tracked: Set<String>) -> GitHubEventAction? {
        guard settings.allows(event: event.event), settings.follows(repo: event.repo),
              let url = event.pullRequestURL, tracked.contains(url) else { return nil }
        return GitHubEventAction(url: url, closing: event.isClosing)
    }

    /// Minutes between timed fetches of the pull requests, or nil for none: the slow rate while the stream is up or has been down for
    /// less than the grace time, otherwise the fallback, which is `base` unless one is set.
    static func pollingMinutes(base: Int, settings: GitHubEventSettings, streaming: Bool, downFor: TimeInterval) -> Int? {
        guard settings.enabled, streaming || downFor < TimeInterval(settings.downSeconds) else {
            return settings.fallbackMinutes == 0 ? base : settings.fallbackMinutes
        }
        return settings.streamMinutes == 0 ? nil : settings.streamMinutes
    }

    static func isDue(last: Date, now: Date, minutes: Int?) -> Bool {
        minutes.map { now.timeIntervalSince(last) >= TimeInterval($0 * 60) } ?? false
    }
}

/// Pull requests waiting to be fetched: events for one within the window share a fetch, which comes the window after the first.
struct PendingRefreshes: Equatable {
    private var first: [String: Date] = [:]

    var isEmpty: Bool { first.isEmpty }

    mutating func add(_ url: String, now: Date) { first[url] = first[url] ?? now }

    mutating func take(now: Date, window: TimeInterval = GitHubEventLogic.debounce) -> [String] {
        let due = first.filter { now.timeIntervalSince($0.value) >= window }.keys.sorted()
        due.forEach { first[$0] = nil }
        return due
    }
}
