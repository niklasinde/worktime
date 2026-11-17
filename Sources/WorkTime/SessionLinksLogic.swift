import Foundation

/// A Jira ticket or a pull request a session has to do with.
enum SessionRef: Hashable, Sendable {
    case jira(String)
    case pullRequest(repo: String, number: Int)

    var id: String {
        switch self {
        case .jira(let key): key
        case .pullRequest(let repo, let number): "\(repo)#\(number)"
        }
    }

    var target: GitHubLink.Target? {
        if case .pullRequest(let repo, let number) = self { GitHubLink.Target(repo: repo, number: number) } else { nil }
    }

    var key: String? {
        if case .jira(let key) = self { key } else { nil }
    }

    init(_ target: GitHubLink.Target) { self = .pullRequest(repo: target.repo, number: target.number) }
}

/// The tickets and pull requests a session mentions, found in its transcript as it grows: each item is read once, a streaming
/// message when it is complete, and a ticket or pull request mentioned again moves to the front.
struct SessionLinks: Equatable, Sendable {
    static let textLimit = 50_000
    static let limit = 12
    private static let batchSize = 10_000

    private(set) var recency: [SessionRef: Int] = [:]
    /// What tools said about a ticket or pull request, and titles found in running text: shown until the app has the real ones.
    private(set) var titles: [SessionRef: SessionRefInfo] = [:]
    private(set) var hints: [SessionRef: String] = [:]
    private var scanned: [String: Int] = [:]
    private var counter = 0

    /// Reads the items that are new or changed since the last call; true when it found anything to reorder.
    @discardableResult
    mutating func update(_ items: [AgentItem], projects: Set<String>) -> Bool {
        var changed = false
        for item in items where !item.streaming {
            let texts = Self.texts(of: item)
            let signature = texts.reduce(texts.count) { $0 &+ $1.utf8.count }
            guard scanned[item.id] != signature else { continue }
            scanned[item.id] = signature
            var seen = Set<SessionRef>()
            let refs = texts.flatMap { Self.references(in: $0, projects: projects) }.filter { seen.insert($0).inserted }
            changed = note(refs) || changed
            changed = learn(from: item, texts: texts, projects: projects) || changed
        }
        return changed
    }

    /// The titles an item gives: what a tool answered about the tickets and pull requests it named, and titles in any text.
    private mutating func learn(from item: AgentItem, texts: [String], projects: Set<String>) -> Bool {
        var changed = false
        if case .tool(_, let summary, let detail, let result?, _, _, _) = item.kind {
            for (ref, info) in SessionTitles.structured(call: summary + "\n" + detail, result: result, projects: projects) {
                let merged = titles[ref]?.overlaid(by: info) ?? info
                if titles[ref] != merged { titles[ref] = merged; changed = true }
            }
        }
        for text in texts {
            for (ref, title) in SessionTitles.hints(in: text, projects: projects) where hints[ref] == nil {
                hints[ref] = title
                changed = true
            }
        }
        return changed
    }

    /// Notes refs seen together, in a message or a branch name: a later batch is newer, and within one the first named comes first.
    @discardableResult
    mutating func note(_ refs: [SessionRef]) -> Bool {
        guard !refs.isEmpty else { return false }
        counter += 1
        for (index, ref) in refs.enumerated() { recency[ref] = counter * Self.batchSize - index }
        return true
    }

    /// The refs newest mention first.
    var recent: [SessionRef] { recency.sorted { $0.value > $1.value }.map(\.key) }

    /// What an item says: a message, or what a tool was asked and answered.
    static func texts(of item: AgentItem) -> [String] {
        switch item.kind {
        case .user(let text), .text(let text): [text]
        case .tool(_, let summary, let detail, let result, _, _, _): [summary, detail, result ?? ""]
        default: []
        }
    }

    /// The pull requests and tickets in `text`, in the order they appear and once each. A ticket counts when its project is one of
    /// `projects`: any word like `UTF-8` would be one otherwise.
    static func references(in text: String, projects: Set<String>) -> [SessionRef] {
        let text = text.utf8.count > textLimit ? String(text.prefix(textLimit)) : text
        func position(of needles: [String]) -> String.Index {
            needles.lazy.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.first ?? text.startIndex
        }
        var found: [(at: String.Index, ref: SessionRef)] = GitHubLink.mentions(in: text).map { target in
            (position(of: ["/\(target.repo)/pull/\(target.number)", "\(target.repo)#\(target.number)"]), SessionRef(target))
        }
        if !projects.isEmpty {
            for match in text.matches(of: #/(?:^|[^A-Za-z0-9_])([A-Z][A-Z0-9]{1,9})-([1-9][0-9]{0,6})(?![0-9A-Za-z])/#) where projects.contains(String(match.1)) {
                found.append((match.range.lowerBound, SessionRef.jira("\(match.1)-\(match.2)")))
            }
        }
        var seen = Set<SessionRef>()
        return found.sorted { $0.at < $1.at }.map(\.ref).filter { seen.insert($0).inserted }
    }

    /// What the rows show, top down: what the session was made for and its branch's pull request, then the rest by when they were
    /// last mentioned, at most `limit`.
    func ordered(pinned: [SessionRef], limit: Int = SessionLinks.limit) -> [SessionRef] {
        var seen = Set<SessionRef>()
        return (pinned + recent).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    /// Every ref there is, for a count that goes past the cap.
    func total(pinned: [SessionRef]) -> Int { Set(pinned + recency.keys).count }
}

/// The Jira projects a session's tickets may belong to: the configured ones, and the prefix of the session's own ticket.
enum SessionProjects {
    static func set(configured: [String], pinned: [SessionRef]) -> Set<String> {
        Set(configured.map { $0.uppercased() } + pinned.compactMap(\.key).compactMap { $0.split(separator: "-").first.map(String.init) })
    }
}

/// Showing a ref: how many rows are open before Show more.
enum SessionLinkRows {
    static let collapsed = 5

    static func visible(_ refs: [SessionRef], expanded: Bool) -> [SessionRef] { expanded ? refs : Array(refs.prefix(collapsed)) }

    static func hidden(_ refs: [SessionRef], expanded: Bool) -> Int { expanded ? 0 : max(0, refs.count - collapsed) }
}
