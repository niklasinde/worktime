import Foundation

/// What `send_to_agent` was given that cannot work.
struct TicketSessionError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A session of an assistant made for one Jira ticket: a topic agent that carries the assistant's key, so everything for that
/// ticket and role (the prompts Main sends, the feedback after) stays in one place.
enum TicketSessions {
    static let policyKey = "agentTicketReuse"
    static let alwaysReuseKey = "agentTicketAlwaysReuse"
    static let limitKey = "agentSessionLimit"
    static let defaultLimit = 3
    static let excerptLimit = 240
    static let excerptLines = 3
    static let nameLimit = 60

    /// What to do when the ticket already has a session of the assistant.
    enum Policy: String, CaseIterable, Identifiable {
        case ask, reuse, new

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask"
            case .reuse: "Always reuse"
            case .new: "Always start a new one"
            }
        }
    }

    enum Resolution: Equatable {
        case create
        case reuse(TopicAgent)
        case ask(TopicAgent)
    }

    enum Answer: String, Codable, Equatable {
        case reuse, startNew, alwaysReuse
    }

    static func policy(defaults: UserDefaults = .standard) -> Policy {
        defaults.string(forKey: policyKey).flatMap(Policy.init) ?? .ask
    }

    static func alwaysReuse(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: alwaysReuseKey) ?? [])
    }

    static func setAlwaysReuse(_ assistant: String, defaults: UserDefaults = .standard) {
        defaults.set(alwaysReuse(defaults: defaults).union([assistant]).sorted(), forKey: alwaysReuseKey)
    }

    // MARK: Keys

    /// The ticket `text` names, checked against the workspace's Jira projects (any project when it has none), or why it is no good.
    static func ticket(_ text: String?, projects: [String]) -> Result<String?, TicketSessionError> {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .success(nil) }
        guard let key = JiraLogic.issueKey(text) else { return .failure(TicketSessionError("\u{201C}\(text)\u{201D} is not a Jira ticket key like PROJ-123.")) }
        let known = projects.map { $0.uppercased() }
        if !known.isEmpty, let project = key.split(separator: "-").first.map(String.init), !known.contains(project) {
            return .failure(TicketSessionError("\(key) is not in this workspace\u{2019}s Jira projects (\(known.joined(separator: ", ")))."))
        }
        return .success(key)
    }

    static func name(ticket: String, role: String) -> String {
        ActivityLogic.truncate("\(ticket) \u{00B7} \(role)", to: nameLimit)
    }

    /// The session for this ticket and assistant, as a topic carrying the assistant and working in the assistant's own folder.
    static func make(entry: AssistantEntry, ticket: String, folder: String, id: String = UUID().uuidString, now: Date) -> TopicAgent {
        TopicAgent(id: id, name: name(ticket: ticket, role: entry.role.name), jiraKey: ticket, folder: folder, created: now, assistant: entry.key)
    }

    /// The newest session of this assistant for this ticket that is not archived.
    static func existing(assistant: String, ticket: String, in topics: [TopicAgent]) -> TopicAgent? {
        topics.filter { $0.assistant == assistant && $0.jiraKey?.caseInsensitiveCompare(ticket) == .orderedSame && !$0.archived }
            .max { $0.created < $1.created }
    }

    /// Every session of any assistant for the ticket, newest first.
    static func sessions(ticket: String, in topics: [TopicAgent]) -> [TopicAgent] {
        topics.filter { $0.assistant != nil && $0.jiraKey?.caseInsensitiveCompare(ticket) == .orderedSame && !$0.archived }
            .sorted { $0.created > $1.created }
    }

    /// Reuse without asking when the setting or the assistant's shortcut says so; a new session when the caller wants one or there is none.
    static func resolve(existing: TopicAgent?, forceNew: Bool, policy: Policy, alwaysReuse: Bool) -> Resolution {
        guard let existing, !forceNew else { return .create }
        if alwaysReuse { return .reuse(existing) }
        switch policy {
        case .ask: return .ask(existing)
        case .reuse: return .reuse(existing)
        case .new: return .create
        }
    }

    // MARK: Words

    /// What the assistant is told about the ticket it works on, after its own instructions.
    static func systemNote(ticket: String, name: String) -> String {
        "This session is for the Jira ticket \(ticket)\u{2014}everything you are asked here is about it, and what you find stays in this conversation so the user can come back to it. "
            + "Read the ticket first with jira_issue. When you are done and nobody is watching, report the outcome with send_to_main in one line that starts with \(ticket)."
    }

    static func systemPrompt(base: String, ticket: String, name: String) -> String {
        base + "\n\n" + systemNote(ticket: ticket, name: name)
    }

    static func createdNote(name: String) -> String { "Created the session \u{201C}\(name)\u{201D} for this ticket." }

    static func reusedNote(name: String, preview: Preview?, now: Date) -> String {
        "Reused the existing session \u{201C}\(name)\u{201D}" + (preview?.updated.map { " (last active \(GitHubLogic.updatedText($0, now: now)))" } ?? "") + "."
    }

    static func chosenNote(_ answer: Answer, name: String) -> String {
        switch answer {
        case .reuse: "The user chose to reuse the existing session \u{201C}\(name)\u{201D}."
        case .alwaysReuse: "The user chose to reuse the existing session \u{201C}\(name)\u{201D}, and to do so from now on for this assistant."
        case .startNew: "The user chose a new session; \u{201C}\(name)\u{201D} was created and the earlier one kept."
        }
    }

    static func timeoutMessage(role: String, ticket: String, minutes: Int) -> String {
        "Timed out after \(minutes) minute\(minutes == 1 ? "" : "s") waiting for the user to choose between reusing the \(role) session for \(ticket) and starting a new one. "
            + "Nothing was sent; ask again when they are back."
    }

    static func slotNote(limit: Int, roleLimit: Int?) -> String {
        var reasons: [String] = []
        if limit > 0 { reasons.append("at most \(limit) assistant session\(limit == 1 ? "" : "s") work at once") }
        if let roleLimit { reasons.append("this assistant runs at most \(roleLimit) at a time") }
        return "It waits for a free slot (\(reasons.joined(separator: ", "))) and starts when one finishes."
    }

    // MARK: Preview

    /// What the user sees of an existing session when asked whether to reuse it.
    struct Preview: Codable, Equatable {
        var key: String
        var title: String
        /// `running`, `waiting for you`, `idle`, `saved` or `error`.
        var state: String
        var updated: Date?
        var excerpt: String

        func line(now: Date) -> String {
            var parts = [title, state]
            if let updated { parts.append(GitHubLogic.updatedText(updated, now: now)) }
            return parts.joined(separator: " \u{00B7} ")
        }
    }

    static func preview(of topic: TopicAgent, state: AgentState?) -> Preview {
        let excerpt = state?.lastResult ?? state?.lastPrompt ?? ""
        return Preview(key: topic.key, title: topic.name, state: stateText(state), updated: state?.updatedAt ?? topic.created,
                       excerpt: clip(excerpt))
    }

    static func stateText(_ state: AgentState?) -> String {
        guard let state else { return "saved" }
        switch state.status {
        case .working: return "running"
        case .waiting: return "waiting for you"
        case .error, .signedOut: return "error"
        case .idle: return state.loaded ? "idle" : "saved"
        }
    }

    /// The first lines of a reply or prompt, on one line.
    static func clip(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let joined = lines.prefix(excerptLines).joined(separator: " / ")
        return joined.count > excerptLimit ? String(joined.prefix(excerptLimit - 1)) + "\u{2026}" : joined
    }

    // MARK: Main's instructions

    static let mainNote = """
        Work on a Jira ticket goes to an assistant with its own session for that ticket, so the feedback comes back to one place and the \
        user can find everything under the ticket: call send_to_agent with agent (the assistant's role name) and ticket (the key), \
        one call per ticket and never several tickets in one prompt. First look at agents_overview with ticket to see what exists. If the \
        assistant already has a session for that ticket, the user is asked whether to reuse it or start a new one, so the call can wait \
        for their answer: say "waiting for your answer on <KEY>" and carry on with the other tickets meanwhile (call them in parallel). \
        new_session forces a new session without asking. Each session may report back with send_to_main; collect the one-line outcomes \
        into one table (ticket, outcome, link) for the user.
        """
}

/// Who runs at once: the number of assistant sessions working is limited, and an assistant can ask for fewer.
enum SessionSlots {
    /// Whether another turn of a session of `role` may start, given the roles of the sessions working now.
    static func hasRoom(role: String, roleLimit: Int?, running: [String], limit: Int) -> Bool {
        if limit > 0, running.count >= limit { return false }
        if let roleLimit, roleLimit > 0, running.filter({ $0 == role }).count >= roleLimit { return false }
        return true
    }

    static func limit(defaults: UserDefaults = .standard) -> Int {
        max(0, defaults.object(forKey: TicketSessions.limitKey) as? Int ?? TicketSessions.defaultLimit)
    }

    /// The waiting sessions that can start now, oldest first, taking each one's slot into account for the next.
    static func startable(waiting: [(id: String, role: String, roleLimit: Int?)], running: [String], limit: Int) -> [String] {
        var running = running, started: [String] = []
        for item in waiting where hasRoom(role: item.role, roleLimit: item.roleLimit, running: running, limit: limit) {
            started.append(item.id)
            running.append(item.role)
        }
        return started
    }
}

/// An existing session of the assistant for the ticket, and the question put to the user about it.
struct TicketAsk: Codable, Equatable, Identifiable {
    var id: String
    var workspace: String
    var assistant: String
    var assistantName: String
    var ticket: String
    var existing: TicketSessions.Preview
    /// The prompt waiting to be sent.
    var text: String
    var created: Date
    var deadline: Date

    var title: String { "A \(assistantName) session for \(ticket) exists" }

    func body(now: Date) -> String {
        "\(existing.line(now: now))" + (existing.excerpt.isEmpty ? "" : " \u{2014} \(existing.excerpt)") + ". Reuse it or start a new one?"
    }

    func expired(now: Date) -> Bool { now >= deadline }
}

enum TicketAsks {
    static let storeKey = "agentTicketAsks"
    static let identifierPrefix = "agent-ticket-ask:"

    static func identifier(_ id: String) -> String { identifierPrefix + id }

    static func encode(_ asks: [TicketAsk]) -> Data { AgentInbox.encode(asks) }

    static func decode(_ data: Data?) -> [TicketAsk] { data.flatMap { AgentInbox.decode([TicketAsk].self, from: $0) } ?? [] }

    /// The question about the ticket of this assistant, when it is already asked: a second send for the same ticket and role waits for the same answer.
    static func pending(assistant: String, ticket: String, in asks: [TicketAsk]) -> TicketAsk? {
        asks.first { $0.assistant == assistant && $0.ticket.caseInsensitiveCompare(ticket) == .orderedSame }
    }

    /// The asks still within their time.
    static func live(_ asks: [TicketAsk], now: Date) -> [TicketAsk] { asks.filter { !$0.expired(now: now) } }
}

/// The agents list by ticket: the sessions of one ticket under a row of their own.
struct TicketGroup: Identifiable, Equatable {
    let ticket: String
    var members: [AgentState]

    var id: String { "ticket:" + ticket }
    var needing: Int { members.filter { AgentOverview.need($0) < .working }.count }
    var working: Int { members.filter { AgentOverview.need($0) == .working }.count }
    var latest: Date? { members.compactMap(\.updatedAt).max() }
    /// The most urgent state of its members.
    var need: AgentOverview.Need { members.map(AgentOverview.need).min() ?? .idle }
}

enum TicketRow: Identifiable, Equatable {
    case agent(AgentState)
    case ticket(TicketGroup)

    var id: String {
        switch self {
        case .agent(let state): state.key
        case .ticket(let group): group.id
        }
    }
}

enum TicketGrouping {
    /// The ticket a session is about: a topic's own, or the one a pull request's title starts with.
    static func ticket(of state: AgentState, projects: Set<String>) -> String? {
        if state.isTopic { return state.jiraKey?.uppercased() }
        guard state.prURL != nil, !projects.isEmpty else { return nil }
        return SessionLinks.references(in: state.title, projects: projects).compactMap(\.key).first
    }

    /// The agents with each ticket's sessions gathered under one row, at the place of the ticket's first session. A ticket gets a row
    /// when an assistant has a session for it or when two sessions are about it; a lone pull request's agent stays as it is.
    static func rows(_ agents: [AgentState], projects: Set<String>) -> [TicketRow] {
        var byTicket: [String: [AgentState]] = [:]
        for state in agents { if let key = ticket(of: state, projects: projects) { byTicket[key, default: []].append(state) } }
        let grouped = byTicket.filter { _, members in members.count > 1 || members.contains { $0.roleKey != nil } }
        var rows: [TicketRow] = [], placed = Set<String>()
        for state in agents {
            guard let key = ticket(of: state, projects: projects), let members = grouped[key] else { rows.append(.agent(state)); continue }
            if placed.insert(key).inserted { rows.append(.ticket(TicketGroup(ticket: key, members: members))) }
        }
        return rows
    }

    /// What a session in a ticket's row is called: its role, or what kind of agent it is.
    static func label(_ state: AgentState) -> String {
        if let role = state.role, state.roleKey != nil { return role }
        if state.isTopic { return "Ticket agent" }
        return state.prURL.map(AgentSessions.shortReference) ?? state.title
    }
}
