import Foundation

/// A lane inside a workspace, such as Review or Verify: it divides the sidebar and the work without splitting the repositories.
struct Space: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// An SF Symbol name.
    var icon = Spaces.defaultIcon
    var color = Spaces.defaultColor
}

extension Space {
    enum CodingKeys: String, CodingKey { case id, name, icon, color }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        self.init(id: id, name: try values.decodeIfPresent(String.self, forKey: .name) ?? id,
                  icon: try values.decodeIfPresent(String.self, forKey: .icon) ?? Spaces.defaultIcon,
                  color: try values.decodeIfPresent(String.self, forKey: .color) ?? Spaces.defaultColor)
    }
}

struct SpaceError: Error, Equatable {
    let message: String
}

enum Spaces {
    static let defaultIcon = "square.stack"
    static let defaultColor = "blue"
    static let colors = ["blue", "green", "orange", "purple", "red", "pink", "teal", "gray"]
    static let selectedKey = "agentSpaceSelected"
    static let all = "all"

    // MARK: Names

    static func id(for name: String, taken: [String]) -> String {
        let base = name.contains { $0.isLetter || $0.isNumber } ? TopicAgents.slug(name) : "space"
        return TopicAgents.uniqueSlug(base, taken: Set(taken))
    }

    /// The space `text` names by id or name, ignoring case.
    static func resolve(_ text: String, in spaces: [Space]) -> Result<Space, SpaceError> {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = spaces.first(where: { $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return .success(found)
        }
        let known = spaces.isEmpty ? "this workspace has no spaces" : "use one of " + spaces.map(\.id).joined(separator: ", ")
        return .failure(SpaceError(message: "No space \u{201C}\(wanted)\u{201D}; \(known)."))
    }

    static func name(of id: String, in spaces: [Space]) -> String { spaces.first { $0.id == id }?.name ?? id }

    // MARK: Tags

    /// The ids that name a space, in the order of the workspace's spaces, and the ones that name none.
    static func split(_ ids: [String], in spaces: [Space]) -> (known: [String], unknown: [String]) {
        let wanted = Set(ids)
        let known = spaces.map(\.id).filter(wanted.contains)
        return (known, ids.filter { id in !spaces.contains { $0.id == id } }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } })
    }

    static func adding(_ id: String, to ids: [String]) -> [String] { ids.contains(id) ? ids : ids + [id] }

    static func toggling(_ id: String, in ids: [String]) -> [String] { ids.contains(id) ? ids.filter { $0 != id } : ids + [id] }

    /// What the user tagged the session with, else its assistant's spaces, kept to the workspace's own spaces; empty for a workspace
    /// without spaces. An explicit empty tag list means none.
    static func effective(tags: [String]?, assistant: [String], in spaces: [Space]) -> [String] {
        split(tags ?? assistant, in: spaces).known
    }

    /// The spaces of an agent as the app writes them to `agents.json`; nil when it has none.
    static func spaces(of state: AgentState, in spaces: [Space], tags: [String: [String]], assistantSpaces: (String) -> [String]) -> [String]? {
        guard !spaces.isEmpty, !Workspaces.isMainKey(state.key) else { return nil }
        let own: [String]? = state.isAssistant ? assistantSpaces(state.key) : nil
        let tagged = state.isAssistant ? nil : tags[state.key]
        let inherited = own ?? state.roleKey.map(assistantSpaces) ?? []
        let found = effective(tags: tagged, assistant: inherited, in: spaces)
        return found.isEmpty ? nil : found
    }

    // MARK: Membership

    static func contains(_ state: AgentState, space: String) -> Bool { state.spaces?.contains(space) ?? false }

    static func isCounted(_ state: AgentState) -> Bool { state.archived != true && !Workspaces.isMainKey(state.key) }

    /// The agents of the space; Main is kept, as the anchor of its workspace.
    static func filter(_ states: [AgentState], space: String?) -> [AgentState] {
        guard let space else { return states }
        return states.filter { Workspaces.isMainKey($0.key) || contains($0, space: space) }
    }

    /// The agents of the space and every agent about the same ticket or pull request as one of them, so a ticket group keeps all its
    /// sessions in each space any of them is in, and appears once in a space however many of its sessions are there.
    static func related(_ agents: [AgentState], space: String?, projects: Set<String>, titles: [String: String] = [:]) -> [AgentState] {
        guard let space else { return agents }
        let subjects = Set(agents.filter { contains($0, space: space) }.compactMap { TicketGrouping.subject(of: $0, projects: projects, titles: titles) })
        return agents.filter {
            contains($0, space: space) || TicketGrouping.subject(of: $0, projects: projects, titles: titles).map(subjects.contains) == true
        }
    }

    static func contains(_ routine: Routine, space: String) -> Bool { routine.spaces?.contains(space) ?? false }

    static func filter(_ routines: [Routine], space: String?) -> [Routine] {
        guard let space else { return routines }
        return routines.filter { contains($0, space: space) }
    }

    /// How many sessions, assistants and routines each space holds, and how many there are in all under `all`.
    static func counts(states: [AgentState], routines: [Routine], spaces: [Space]) -> [String: Int] {
        let counted = states.filter(isCounted)
        var counts: [String: Int] = [all: counted.count + routines.count]
        for space in spaces {
            counts[space.id] = counted.filter { contains($0, space: space.id) }.count + routines.filter { contains($0, space: space.id) }.count
        }
        return counts
    }

    /// Whether something in the space waits for the user: a permission, an unseen result or an error.
    static func needsUser(_ states: [AgentState], space: String?) -> Bool {
        states.filter(isCounted).contains { state in
            AgentOverview.need(state) < .working && (space.map { contains(state, space: $0) } ?? true)
        }
    }

    // MARK: Chosen space

    /// The space chosen for a workspace out of the saved `workspace=space` pairs, nil for All or a space that is gone.
    static func chosen(_ raw: String, workspace: String, in spaces: [Space]) -> String? {
        let pairs = raw.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        return pairs.first { $0.0 == workspace }.map(\.1).flatMap { id in spaces.contains { $0.id == id } ? id : nil }
    }

    static func choosing(_ space: String?, workspace: String, in raw: String) -> String {
        var pairs = raw.split(separator: ",").map(String.init).filter { !$0.hasPrefix(workspace + "=") }
        if let space { pairs.append("\(workspace)=\(space)") }
        return pairs.sorted().joined(separator: ",")
    }

    // MARK: Sending between spaces

    /// The first usable assistant meant for the space that is not the one the work comes from.
    static func nextAssistant(for space: String, excluding key: String?, in entries: [AssistantEntry]) -> AssistantEntry? {
        entries.first { $0.role.isUsable && $0.key != key && $0.role.spaces.contains(space) }
    }

    /// The prompt offered when work moves to a space and an assistant starts on it, from what the previous assistant reported.
    static func handoffPrompt(space: Space, subject: SessionSubject?, from role: String?, outcome: String?) -> String {
        var text = subject.map { "\(space.name) \($0.label)." } ?? "\(space.name) this."
        if let outcome = outcome.map(TicketSessions.clip), !outcome.isEmpty {
            text += "\n\n" + (role.map { "What \($0) reported" } ?? "What was reported") + ": " + outcome
        }
        return text
    }

    /// Moving work to a space: which sessions get the tag, and, when a next assistant is meant for it, the prompt to start it with.
    static func handoff(states: [AgentState], to space: Space, subject: SessionSubject?, entries: [AssistantEntry]) -> SpaceHandoff {
        let live = states.filter { $0.archived != true }
        let source = live.filter { $0.roleKey != nil && $0.lastResult != nil }.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) } ?? live.first
        return SpaceHandoff(keys: live.map(\.key), space: space, subject: subject,
                            assistant: nextAssistant(for: space.id, excluding: source?.roleKey, in: entries),
                            prompt: handoffPrompt(space: space, subject: subject, from: source?.roleKey == nil ? nil : source?.role, outcome: source?.lastResult))
    }

    // MARK: Words

    static func line(_ ids: [String], in spaces: [Space]) -> String? {
        ids.isEmpty ? nil : ids.map { name(of: $0, in: spaces) }.joined(separator: ", ")
    }

    /// What the app says about the ids a role file names that no space of the workspace has.
    static func warnings(for role: AssistantRole, in spaces: [Space]) -> [AssistantProblem] {
        let unknown = split(role.spaces, in: spaces).unknown
        guard !unknown.isEmpty else { return [] }
        let known = spaces.isEmpty ? "the workspace has no spaces" : "use " + spaces.map(\.id).joined(separator: ", ")
        return unknown.map { AssistantProblem(line: nil, message: "Unknown space \u{201C}\($0)\u{201D}; \(known). It is kept in the file and ignored.") }
    }
}

/// Work moving to a space, as the sheet that confirms it shows it.
struct SpaceHandoff: Identifiable, Equatable {
    let id = UUID()
    var keys: [String]
    var space: Space
    var subject: SessionSubject?
    var assistant: AssistantEntry?
    var prompt: String
}
