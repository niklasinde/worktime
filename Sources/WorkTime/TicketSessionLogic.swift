import Foundation

/// What `send_to_agent` was given that cannot work.
struct TicketSessionError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What an assistant's session is about: a Jira ticket, or a pull request that names none.
enum SessionSubject: Equatable, Hashable {
    case ticket(String)
    case pullRequest(String)

    /// The group's id in the agents list and on the Main page: `ticket:ACME-1` or `pr:https://github.com/\u{2026}`.
    var key: String {
        switch self {
        case .ticket(let key): "ticket:" + key
        case .pullRequest(let url): "pr:" + url
        }
    }

    /// What people call it: the ticket's key, or the pull request as `repo#12`.
    var label: String {
        switch self {
        case .ticket(let key): key
        case .pullRequest(let url): AgentSessions.shortReference(url)
        }
    }

    var ticket: String? { if case .ticket(let key) = self { key } else { nil } }
    var pullRequest: String? { if case .pullRequest(let url) = self { url } else { nil } }

    init?(key: String) {
        if key.hasPrefix("ticket:"), key.count > 7 { self = .ticket(String(key.dropFirst(7))) }
        else if key.hasPrefix("pr:"), GitHubLink.pullRequest(at: String(key.dropFirst(3))) != nil { self = .pullRequest(String(key.dropFirst(3))) }
        else { return nil }
    }

    static func isKey(_ key: String) -> Bool { SessionSubject(key: key) != nil }
}

/// A session of an assistant made for one Jira ticket or pull request: a topic agent that carries the assistant's key, so everything for
/// that subject and role (the prompts Main sends, the feedback after) stays in one place, and stays after it is closed.
enum TicketSessions {
    static let policyKey = "agentTicketReuse"
    static let alwaysReuseKey = "agentTicketAlwaysReuse"
    static let limitKey = "agentSessionLimit"
    static let defaultLimit = 3
    static let excerptLimit = 240
    static let excerptLines = 3
    static let nameLimit = 60

    /// What to do when the subject already has a session of the assistant.
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

    /// The pull request `text` names as its canonical address, or why it is no good.
    static func pullRequest(_ text: String?) -> Result<String?, TicketSessionError> {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .success(nil) }
        guard let target = GitHubLink.pasted(text) else {
            return .failure(TicketSessionError("\u{201C}\(text)\u{201D} is not a GitHub pull request address."))
        }
        return .success(target.url)
    }

    /// The ticket a pull request's title names, among the workspace's Jira projects; nil when it names none.
    static func ticket(inTitle title: String?, projects: [String]) -> String? {
        guard let title, !projects.isEmpty else { return nil }
        return SessionLinks.references(in: title, projects: Set(projects.map { $0.uppercased() })).compactMap(\.key).first
    }

    static func name(subject: SessionSubject, role: String) -> String {
        ActivityLogic.truncate("\(subject.label) \u{00B7} \(role)", to: nameLimit)
    }

    /// The session for this subject and assistant, as a topic carrying the assistant and working in the assistant's own folder.
    static func make(entry: AssistantEntry, subject: SessionSubject, folder: String, id: String = UUID().uuidString, now: Date) -> TopicAgent {
        var topic = TopicAgent(id: id, name: name(subject: subject, role: entry.role.name), jiraKey: subject.ticket, folder: folder, created: now,
                               assistant: entry.key)
        topic.pullRequestURL = subject.pullRequest
        return topic
    }

    /// Whether the topic is this assistant's session for the subject.
    static func isSession(_ topic: TopicAgent, assistant: String?, subject: SessionSubject) -> Bool {
        guard topic.assistant != nil, assistant == nil || topic.assistant == assistant else { return false }
        switch subject {
        case .ticket(let key): return topic.jiraKey?.caseInsensitiveCompare(key) == .orderedSame
        case .pullRequest(let url): return topic.jiraKey == nil && topic.pullRequestURL == url
        }
    }

    /// The newest session of this assistant for this subject that is not archived.
    static func existing(assistant: String, subject: SessionSubject, in topics: [TopicAgent]) -> TopicAgent? {
        topics.filter { isSession($0, assistant: assistant, subject: subject) && !$0.archived }.max { $0.created < $1.created }
    }

    /// Every session of any assistant for the subject, newest first, closed ones too when `archived` says so.
    static func sessions(subject: SessionSubject, in topics: [TopicAgent], archived: Bool = false) -> [TopicAgent] {
        topics.filter { isSession($0, assistant: nil, subject: subject) && (archived || !$0.archived) }.sorted { $0.created > $1.created }
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

    /// What the assistant is told about what it works on, after its own instructions.
    static func systemNote(subject: SessionSubject) -> String {
        switch subject {
        case .ticket(let key):
            return "This session is for the Jira ticket \(key)\u{2014}everything you are asked here is about it, and what you find stays in this conversation so the user can come back to it. "
                + "Read the ticket first with jira_issue. When you are done and nobody is watching, report the outcome with send_to_main in one line that starts with \(key)."
        case .pullRequest(let url):
            return "This session is for the pull request \(url), which names no ticket\u{2014}everything you are asked here is about it, and what you find stays in this conversation so the user can come back to it. "
                + "When you are done and nobody is watching, report the outcome with send_to_main in one line that starts with \(AgentSessions.shortReference(url))."
        }
    }

    static func systemPrompt(base: String, subject: SessionSubject) -> String {
        base + "\n\n" + systemNote(subject: subject)
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

    static func timeoutMessage(role: String, subject: String, minutes: Int) -> String {
        "Timed out after \(minutes) minute\(minutes == 1 ? "" : "s") waiting for the user to choose between reusing the \(role) session for \(subject) and starting a new one. "
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
        new_session forces a new session without asking. When the work is about a pull request that names no ticket (nothing in its title, branch \
        or linked Jira), pass pr_url with the assistant instead and it gets a session for that pull request the same way. Each session may report \
        back with send_to_main; collect the one-line outcomes into one table (ticket or pull request, outcome, link) for the user. For verify, \
        review or develop requests always use agent plus ticket, never pr_url alone (that talks to the pull request's own agent); if a send is \
        refused, read the error and retry with the form it suggests instead of asking the user. When the workspace has spaces (lanes such as \
        Review, Develop or Verify) and the user names a lane for a handoff, also pass space: the session is put in that space too, and \
        agents_overview with space shows what is in it.
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

/// An existing session of the assistant for the ticket or pull request, and the question put to the user about it.
struct TicketAsk: Codable, Equatable, Identifiable {
    var id: String
    var workspace: String
    var assistant: String
    var assistantName: String
    var ticket: String?
    var pullRequest: String?
    var existing: TicketSessions.Preview
    /// The prompt waiting to be sent.
    var text: String
    var created: Date
    var deadline: Date
    /// What started it, shown in the session's timeline.
    var origin: String?
    /// A space id to add to the session the prompt ends up in.
    var space: String?

    var subject: SessionSubject { ticket.map(SessionSubject.ticket) ?? pullRequest.map(SessionSubject.pullRequest) ?? .ticket("") }

    var title: String { "A \(assistantName) session for \(subject.label) exists" }

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

    /// The question about the subject of this assistant, when it is already asked: a second send for the same subject and role is turned away.
    static func pending(assistant: String, subject: SessionSubject, in asks: [TicketAsk]) -> TicketAsk? {
        asks.first { ask in
            guard ask.assistant == assistant else { return false }
            switch (ask.subject, subject) {
            case (.ticket(let a), .ticket(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
            case (.pullRequest(let a), .pullRequest(let b)): return a == b
            default: return false
            }
        }
    }

    /// The asks still within their time.
    static func live(_ asks: [TicketAsk], now: Date) -> [TicketAsk] { asks.filter { !$0.expired(now: now) } }
}

/// A pull request in a ticket's row: one chip for the pull request, with the agents and sessions about it.
struct PullRequestChip: Identifiable, Equatable {
    let url: String
    var sessions: [AgentState]

    var id: String { url }
    var label: String { AgentSessions.shortReference(url) }
}

/// The agents list by ticket or pull request: the sessions about one subject under a row of their own. A ticket's pull requests show as
/// chips on its row, and closed sessions stay under "Earlier".
struct TicketGroup: Identifiable, Equatable {
    let subject: SessionSubject
    /// Every agent about the subject, closed sessions too.
    var members: [AgentState]

    var id: String { subject.key }
    var ticket: String? { subject.ticket }
    var live: [AgentState] { members.filter { $0.archived != true } }
    var earlier: [AgentState] { members.filter { $0.archived == true } }
    var needing: Int { live.filter { AgentOverview.need($0) < .working }.count }
    var working: Int { live.filter { AgentOverview.need($0) == .working }.count }
    var latest: Date? { members.compactMap(\.updatedAt).max() }
    /// The most urgent state of its live members.
    var need: AgentOverview.Need { live.map(AgentOverview.need).min() ?? .idle }

    static func pullRequest(of state: AgentState) -> String? { state.prURL ?? state.sessionPR }

    /// A ticket's pull requests, once each, in the order they come.
    var chips: [PullRequestChip] {
        guard subject.ticket != nil else { return [] }
        var chips: [PullRequestChip] = []
        for state in live {
            guard let url = Self.pullRequest(of: state) else { continue }
            if let index = chips.firstIndex(where: { $0.url == url }) { chips[index].sessions.append(state) } else { chips.append(PullRequestChip(url: url, sessions: [state])) }
        }
        return chips
    }

    /// The live agents shown as rows: all of them for a pull request, and for a ticket the ones that are not a pull request's.
    var rows: [AgentState] { subject.ticket == nil ? live : live.filter { Self.pullRequest(of: $0) == nil } }
}

enum TicketRow: Identifiable, Equatable {
    case agent(AgentState)
    case group(TicketGroup)

    var id: String {
        switch self {
        case .agent(let state): state.key
        case .group(let group): group.id
        }
    }
}

enum TicketGrouping {
    /// What an agent is about: its ticket, else its pull request. A pull request that names a ticket in its title belongs to the ticket.
    static func subject(of state: AgentState, projects: Set<String>, titles: [String: String] = [:]) -> SessionSubject? {
        func named(_ url: String) -> SessionSubject {
            let title = titles[url] ?? (state.prURL == url ? state.title : nil)
            if let title, !projects.isEmpty, let key = SessionLinks.references(in: title, projects: projects).compactMap(\.key).first { return .ticket(key) }
            return .pullRequest(url)
        }
        if state.isTopic {
            if let key = state.jiraKey { return .ticket(key.uppercased()) }
            return state.sessionPR.map(named)
        }
        return state.prURL.map(named)
    }

    /// The ticket a pull request's agent is about, for the places that only know tickets.
    static func ticket(of state: AgentState, projects: Set<String>) -> String? {
        subject(of: state, projects: projects)?.ticket
    }

    /// The agents with each subject's sessions gathered under one row, at the place of the subject's first agent. A ticket gets a row when an
    /// assistant has a session for it or when two agents are about it, a pull request when an assistant has a session for it; a lone
    /// pull request's agent stays as it is. Closed sessions only ever show inside a row.
    static func rows(_ agents: [AgentState], projects: Set<String>, titles: [String: String] = [:]) -> [TicketRow] {
        var bySubject: [SessionSubject: [AgentState]] = [:]
        for state in agents { if let subject = subject(of: state, projects: projects, titles: titles) { bySubject[subject, default: []].append(state) } }
        let grouped = bySubject.filter { subject, members in
            members.contains { $0.roleKey != nil } || (subject.ticket != nil && members.count > 1)
        }
        var rows: [TicketRow] = [], placed = Set<SessionSubject>()
        for state in agents {
            guard let subject = subject(of: state, projects: projects, titles: titles), let members = grouped[subject] else {
                if state.archived != true { rows.append(.agent(state)) }
                continue
            }
            if placed.insert(subject).inserted { rows.append(.group(TicketGroup(subject: subject, members: members))) }
        }
        return rows
    }

    /// The group with this id among the agents, for the page of a ticket or pull request.
    static func group(_ id: String, in agents: [AgentState], projects: Set<String>, titles: [String: String] = [:]) -> TicketGroup? {
        for case .group(let group) in rows(agents, projects: projects, titles: titles) where group.id == id { return group }
        guard let subject = SessionSubject(key: id) else { return nil }
        let members = agents.filter { self.subject(of: $0, projects: projects, titles: titles) == subject }
        return members.isEmpty ? nil : TicketGroup(subject: subject, members: members)
    }

    /// What a session in a row is called: its role, or what kind of agent it is.
    static func label(_ state: AgentState) -> String {
        if let role = state.role, state.roleKey != nil { return role }
        if state.isTopic { return "Ticket agent" }
        return state.prURL.map(AgentSessions.shortReference) ?? state.title
    }
}
