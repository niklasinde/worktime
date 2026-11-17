import Foundation

/// What a row of the Related list knows about a ticket or pull request besides its key: a title, and where it stands.
struct SessionRefInfo: Equatable, Codable, Sendable {
    var title = ""
    /// A ticket's status name, like `In Progress`, and Jira's category for it (`new`, `indeterminate`, `done`).
    var status: String?
    var category: String?
    /// A pull request's `open`, `merged` or `closed`, whether it is a draft, and its checks (`passed`, `failed`, `running`, `none`).
    var state: String?
    var isDraft = false
    var checks: String?

    init(title: String = "", status: String? = nil, category: String? = nil, state: String? = nil, isDraft: Bool = false, checks: String? = nil) {
        self.title = title
        self.status = status
        self.category = category
        self.state = state
        self.isDraft = isDraft
        self.checks = checks
    }

    init(ticket: JiraTicket) {
        self.init(title: ticket.summary, status: ticket.status.isEmpty ? nil : ticket.status, category: ticket.category?.rawValue)
    }

    init(pullRequest: GitHubPR) {
        self.init(title: pullRequest.title, state: pullRequest.state.rawValue, isDraft: pullRequest.isDraft, checks: pullRequest.checks.rawValue)
    }

    /// Shown at once from the transcript, nothing to fetch: a title, and for a ticket its status or for a pull request its state.
    func isComplete(for ref: SessionRef) -> Bool {
        guard !title.isEmpty else { return false }
        return ref.key != nil ? status != nil : state != nil
    }

    /// How a ticket's status reads: Jira's category when it came with the status, else a guess from well-known names.
    var statusKind: JiraStatusCategory? {
        if let category, let known = JiraStatusCategory(rawValue: category) { return known }
        guard let name = status?.lowercased() else { return nil }
        if ["done", "resolved", "closed", "released", "complete", "completed"].contains(name) { return .done }
        if ["progress", "review", "test", "verif"].contains(where: { name.contains($0) }) { return .inProgress }
        return nil
    }

    /// Done tickets and merged or closed pull requests hardly change, so they are looked up less often.
    var isSettled: Bool { category == JiraStatusCategory.done.rawValue || state == "merged" || state == "closed" }

    /// This info with what `other` knows laid over it: its title when it has one, and the fields it has.
    func overlaid(by other: SessionRefInfo?) -> SessionRefInfo {
        guard let other else { return self }
        var merged = self
        if !other.title.isEmpty { merged.title = other.title }
        if let status = other.status { merged.status = status }
        if let category = other.category { merged.category = category }
        if let state = other.state {
            merged.state = state
            merged.isDraft = other.isDraft
        }
        if let checks = other.checks { merged.checks = checks }
        return merged
    }

    /// A pull request to draw the same status mark as the GitHub page, from what is known of it.
    func pullRequest(for target: GitHubLink.Target, updated: Date) -> GitHubPR {
        GitHubPR(url: target.url, number: target.number, title: title, repo: target.repo, isDraft: isDraft,
                 state: GitHubPR.State(rawValue: state ?? "") ?? .open, updated: updated,
                 checks: GitHubPR.Checks(rawValue: checks ?? "") ?? .none)
    }
}

extension SessionRef {
    /// Cached under one name however the key was written: a repository is the same in any case.
    var cacheKey: String { id.lowercased() }
}

/// A looked-up ticket or pull request as the cache keeps it: when it was fetched, and nil when the lookup found nothing.
struct SessionRefEntry: Equatable, Codable, Sendable {
    var info: SessionRefInfo?
    var fetched: Date
}

/// Finding the titles the transcript did not give: what to fetch, which batches, how long an answer is kept and when to try again.
enum SessionRefLookup {
    static let openLifetime: TimeInterval = 20 * 60
    static let settledLifetime: TimeInterval = 6 * 3600
    static let missingLifetime: TimeInterval = 3600
    /// After a failed lookup, nothing is asked again for this long: a token that is not set up changes more slowly than a dropped connection.
    static let failureBackoff: TimeInterval = 600
    static let unconfiguredBackoff: TimeInterval = 1800
    static let ticketBatch = 40
    static let pullRequestBatch = 15
    static let cacheLimit = 300

    struct Plan: Equatable {
        var tickets: [[String]] = []
        var pullRequests: [[GitHubLink.Target]] = []

        var isEmpty: Bool { tickets.isEmpty && pullRequests.isEmpty }
        var ids: [String] { tickets.flatMap { $0 } + pullRequests.flatMap { $0 }.map { SessionRef.pullRequest(repo: $0.repo, number: $0.number).cacheKey } }
    }

    static func isFresh(_ entry: SessionRefEntry, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.fetched)
        guard let info = entry.info else { return age < missingLifetime }
        return age < (info.isSettled ? settledLifetime : openLifetime)
    }

    /// What to ask for now, in batches: the refs that are not in `skip` (the app has them, or the transcript told enough), have no
    /// fresh answer, are not backing off from a failure and are not already being asked for.
    static func plan(_ refs: [SessionRef], skip: Set<String>, cache: [String: SessionRefEntry], backoff: [String: Date],
                     inFlight: Set<String>, now: Date) -> Plan {
        var tickets: [String] = [], pullRequests: [GitHubLink.Target] = []
        var seen = Set<String>()
        for ref in refs {
            let key = ref.cacheKey
            guard seen.insert(key).inserted, !skip.contains(key), !inFlight.contains(key) else { continue }
            if let entry = cache[key], isFresh(entry, now: now) { continue }
            if let until = backoff[key], until > now { continue }
            if let name = ref.key { tickets.append(name) } else if let target = ref.target { pullRequests.append(target) }
        }
        return Plan(tickets: batches(tickets, size: ticketBatch), pullRequests: batches(pullRequests, size: pullRequestBatch))
    }

    private static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The search that finds the tickets; the keys are checked, so none of them can change the query.
    static func jql(_ keys: [String]) -> String {
        "key in (" + keys.filter { $0.range(of: #"^[A-Z][A-Z0-9]{1,9}-[0-9]{1,7}$"#, options: .regularExpression) != nil }
            .map { "\"\($0)\"" }.joined(separator: ", ") + ")"
    }

    /// An entry for every ticket asked for: what the search found, and nothing for the keys it did not return (a ticket the sign-in cannot see).
    static func entries(forTickets requested: [String], found: [JiraTicket], now: Date) -> [String: SessionRefEntry] {
        let byKey = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(requested.map { key in
            (SessionRef.jira(key).cacheKey, SessionRefEntry(info: byKey[key].map(SessionRefInfo.init(ticket:)), fetched: now))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The same for pull requests, matched to what was asked for by address.
    static func entries(forPullRequests requested: [GitHubLink.Target], found: [GitHubPR], now: Date) -> [String: SessionRefEntry] {
        let byURL = Dictionary(found.map { ($0.url.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(requested.map { target in
            (SessionRef.pullRequest(repo: target.repo, number: target.number).cacheKey,
             SessionRefEntry(info: byURL[target.url.lowercased()].map(SessionRefInfo.init(pullRequest:)), fetched: now))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// When to ask again after a failed lookup.
    static func retryAfter(unconfigured: Bool, now: Date) -> Date {
        now.addingTimeInterval(unconfigured ? unconfiguredBackoff : failureBackoff)
    }

    /// What a row shows, a field at a time from the most trusted source that has it: the app's own data, then what was fetched,
    /// then what a tool said in the transcript, then a title found in running text.
    static func resolve(live: SessionRefInfo?, fetched: SessionRefEntry?, transcript: SessionRefInfo?, hint: String?) -> SessionRefInfo? {
        var info = SessionRefInfo(title: hint ?? "")
        info = info.overlaid(by: transcript).overlaid(by: fetched?.info).overlaid(by: live)
        return info == SessionRefInfo() ? nil : info
    }

    /// The cache with its oldest answers dropped past `limit`.
    static func pruned(_ cache: [String: SessionRefEntry], limit: Int = cacheLimit) -> [String: SessionRefEntry] {
        guard cache.count > limit else { return cache }
        return Dictionary(cache.sorted { $0.value.fetched > $1.value.fetched }.prefix(limit).map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    static func encode(_ cache: [String: SessionRefEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(pruned(cache))) ?? Data()
    }

    static func decode(_ data: Data?) -> [String: SessionRefEntry] {
        guard let data else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: SessionRefEntry].self, from: data)) ?? [:]
    }
}
