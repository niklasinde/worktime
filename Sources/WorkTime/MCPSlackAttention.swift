import Foundation

/// What the Slack section of `attention` keeps between calls, so a repeated call does not wait for Slack again.
final class SlackAttentionCache: @unchecked Sendable {
    static let shared = SlackAttentionCache()
    static let ttl: TimeInterval = 60
    static let identityTtl: TimeInterval = 300

    struct Entry: Equatable {
        let text: String
        let date: Date
    }

    enum Lookup: Equatable {
        case fresh(Entry), stale(Entry), missing
    }

    /// One fetch under way; callers wait on it for as long as they can afford.
    final class Flight: @unchecked Sendable {
        private let group = DispatchGroup()
        fileprivate(set) var text = ""

        init() { group.enter() }

        fileprivate func finish(_ text: String) {
            self.text = text
            group.leave()
        }

        func wait(until deadline: Date) -> Bool {
            group.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0)) == .success
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var identities: [String: (identity: SlackIdentity, date: Date)] = [:]
    private var userNames: [String: [String: String]] = [:]
    private var flights: [String: Flight] = [:]

    func lookup(_ key: String, now: Date) -> Lookup {
        lock.withLock {
            guard let entry = entries[key] else { return .missing }
            return now.timeIntervalSince(entry.date) < Self.ttl ? .fresh(entry) : .stale(entry)
        }
    }

    func identity(_ key: String, now: Date) -> SlackIdentity? {
        lock.withLock { identities[key].flatMap { now.timeIntervalSince($0.date) < Self.identityTtl ? $0.identity : nil } }
    }

    func remember(identity: SlackIdentity, _ key: String, now: Date) {
        lock.withLock { identities[key] = (identity, now) }
    }

    func names(_ key: String) -> [String: String] { lock.withLock { userNames[key] ?? [:] } }

    func remember(names: [String: String], _ key: String) {
        lock.withLock { userNames[key, default: [:]].merge(names) { $1 } }
    }

    /// The fetch already running for `key`, or a new one that `start` sets going.
    func join(_ key: String, start: (Flight) -> Void) -> Flight {
        lock.withLock {
            if let running = flights[key] { return running }
            let flight = Flight()
            flights[key] = flight
            start(flight)
            return flight
        }
    }

    /// Ends the flight; `entry` is kept for the next calls, nil when the fetch failed.
    func finish(_ key: String, _ flight: Flight, text: String, entry: Entry?) {
        lock.withLock {
            if let entry { entries[key] = entry }
            flights[key] = nil
        }
        flight.finish(text)
    }
}

enum SlackAttention {
    static let budget: TimeInterval = 3
    static let timeout: TimeInterval = 25
    static let shown = 10
    static let nameCap = 12
    static let loading = "Slack still loading: call `attention` with section=slack in a moment.\n"

    static func marked(_ entry: SlackAttentionCache.Entry, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return "As of \(formatter.string(from: entry.date)).\n" + entry.text
    }

    /// The user ids to look up: each once, in the order they appear, without the known ones, at most `cap`.
    static func lookups(_ wanted: [String], known: [String: String], cap: Int = nameCap) -> [String] {
        var seen = Set<String>()
        return Array(wanted.filter { known[$0] == nil && seen.insert($0).inserted }.prefix(cap))
    }

    /// Sets the fetch going at once and returns what waits for the section: the cached text when there is one, otherwise the fetch
    /// for up to `wait` seconds and then the note that it is still loading while the fetch finishes into the cache.
    static func start(key: String, cache: SlackAttentionCache = .shared, wait: TimeInterval = budget, now: @escaping @Sendable () -> Date = { Date() },
                      timeZone: TimeZone = .current, fetch: @escaping @Sendable () async throws -> String) -> () -> String {
        func launch() -> SlackAttentionCache.Flight {
            cache.join(key) { flight in
                Task.detached {
                    do {
                        let text = try await fetch()
                        cache.finish(key, flight, text: text, entry: SlackAttentionCache.Entry(text: text, date: now()))
                    } catch {
                        cache.finish(key, flight, text: "Slack could not be read: \(SlackError.from(error).message)\n", entry: nil)
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(wait)
        switch cache.lookup(key, now: now()) {
        case .fresh(let entry):
            return { marked(entry, timeZone: timeZone) }
        case .stale(let entry):
            _ = launch()
            return { marked(entry, timeZone: timeZone) }
        case .missing:
            let flight = launch()
            return { flight.wait(until: deadline) ? flight.text : loading }
        }
    }

    /// Mentions still needing the user and unread DMs: the two searches run together, then the names the lines need.
    static func section(client: SlackAPI, key: String, cache: SlackAttentionCache = .shared, marks: [String: SlackHandled], now: Date) async throws -> String {
        let me: SlackIdentity
        if let known = cache.identity(key, now: now) { me = known } else {
            me = try await client.identity()
            cache.remember(identity: me, key, now: now)
        }
        async let mentioned = client.annotate(try await client.mentions(of: me, now: now), me: me.userID, marks: marks).mentions.filter { $0.handled == nil }
        async let directed = client.directMessages(of: me, names: cache.names(key), now: now)
        let (mentions, direct) = try await (mentioned, directed)
        cache.remember(names: direct.names, key)
        let messages = Array(SlackLogic.merged(mentions: mentions, direct: SlackLogic.applying(marks, to: direct.messages).filter { $0.handled == nil }).prefix(shown))
        guard !messages.isEmpty else { return "No mentions or unread DMs.\n" }
        let wanted = messages.flatMap { [$0.author].compactMap { $0 } + SlackLogic.mentionedUsers(in: $0.text) }
        cache.remember(names: await client.userNames(lookups(wanted, known: cache.names(key))), key)
        let names = cache.names(key)
        return messages.map { message in
            let who = message.author.map { names[$0] ?? $0 } ?? "someone"
            let kind = message.kind == .direct ? "DM" + (message.unread.map { " (\($0) unread)" } ?? "") : "mention in \(message.place)"
            let link = SlackLogic.webLink(message, workspace: me.url).map { "\n  \($0.absoluteString)" } ?? ""
            return "- \(kind) from \(who), \(GitHubLogic.updatedText(message.date, now: now)): "
                + AgentOverview.oneLine(ActivityLogic.truncate(SlackLogic.clean(message.text, names: names), to: 200)) + link
        }.joined(separator: "\n") + "\n"
    }
}
