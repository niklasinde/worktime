import Foundation

struct JiraPerson: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// A move the ticket can make from its status now, with the fields Jira insists on filling in.
struct JiraTransition: Equatable, Identifiable, Sendable {
    struct Option: Equatable, Hashable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    struct Field: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case choice(multiple: Bool)
            case text
            case unsupported
        }

        let key: String
        let name: String
        let kind: Kind
        let options: [Option]

        var id: String { key }
    }

    let id: String
    let name: String
    let status: String
    let category: JiraStatusCategory?
    /// Only the required fields without a default; the others are left to Jira.
    let fields: [Field]

    /// A required field this app cannot fill in, so the move is done in Jira.
    var needsJira: Bool { fields.contains { $0.kind == .unsupported } }
}

/// The writes of the Jira page, which only the user's own clicks start: request builders, answers and the local effect of a change.
enum JiraWrite {
    static let commentLimit = 30_000

    static func transitionsPath(_ key: String) -> String { "/rest/api/3/issue/\(key)/transitions?expand=transitions.fields" }
    static func transitionPath(_ key: String) -> String { "/rest/api/3/issue/\(key)/transitions" }
    static func assigneePath(_ key: String) -> String { "/rest/api/3/issue/\(key)/assignee" }
    static func commentPath(_ key: String) -> String { "/rest/api/3/issue/\(key)/comment" }

    /// People matching `query`; with an issue key only those who can be assigned to it.
    static func usersPath(query: String, issueKey: String? = nil) -> String {
        var components = URLComponents()
        components.path = issueKey == nil ? "/rest/api/3/user/search" : "/rest/api/3/user/assignable/search"
        components.queryItems = [issueKey.map { URLQueryItem(name: "issueKey", value: $0) }, URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "maxResults", value: "20")].compactMap { $0 }
        return components.percentEncodedPath + "?" + (components.percentEncodedQuery ?? "")
    }

    // MARK: Answers

    static func parseTransitions(_ data: Data) throws -> [JiraTransition] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["transitions"] as? [[String: Any]] else { throw JiraError.failed("unexpected response") }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            let target = entry["to"] as? [String: Any] ?? [:]
            let category = ((target["statusCategory"] as? [String: Any])?["key"] as? String).flatMap(JiraStatusCategory.init(rawValue:))
            let fields = (entry["fields"] as? [String: Any] ?? [:]).compactMap { key, value in field(key, value as? [String: Any] ?? [:]) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return JiraTransition(id: id, name: name, status: target["name"] as? String ?? name, category: category, fields: fields)
        }
    }

    private static func field(_ key: String, _ value: [String: Any]) -> JiraTransition.Field? {
        guard value["required"] as? Bool == true, value["hasDefaultValue"] as? Bool != true else { return nil }
        let schema = value["schema"] as? [String: Any] ?? [:]
        let options = (value["allowedValues"] as? [[String: Any]] ?? []).compactMap { option -> JiraTransition.Option? in
            guard let id = option["id"] as? String else { return nil }
            return JiraTransition.Option(id: id, name: option["name"] as? String ?? option["value"] as? String ?? id)
        }
        let kind: JiraTransition.Field.Kind = !options.isEmpty ? .choice(multiple: schema["type"] as? String == "array")
            : schema["type"] as? String == "string" ? .text : .unsupported
        return JiraTransition.Field(key: key, name: value["name"] as? String ?? key, kind: kind, options: options)
    }

    static func parseUsers(_ data: Data) throws -> [JiraPerson] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw JiraError.failed("unexpected response") }
        return list.compactMap { user in
            guard let id = user["accountId"] as? String, let name = user["displayName"] as? String,
                  user["active"] as? Bool ?? true, user["accountType"] as? String ?? "atlassian" == "atlassian" else { return nil }
            return JiraPerson(id: id, name: name)
        }
    }

    static func parseComment(_ data: Data) throws -> JiraIssue.Comment {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JiraError.failed("unexpected response") }
        return JiraIssue.Comment(author: (object["author"] as? [String: Any])?["displayName"] as? String ?? "Someone",
                                 created: (object["created"] as? String).flatMap(JiraLogic.date), body: JiraLogic.text(object["body"]))
    }

    /// What Jira said about a change it did not make.
    static func refusal(status: Int, body: Data) -> JiraError {
        switch status {
        case 401: return .unauthorized
        case 429: return .rateLimited
        default:
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let errors = (object["errors"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.compactMap { $0.value as? String }
            let detail = ((object["errorMessages"] as? [String] ?? []) + errors).joined(separator: "; ")
            if !detail.isEmpty { return .refused(ActivityLogic.truncate(detail, to: 200)) }
            switch status {
            case 403: return .refused("this account may not change that ticket")
            case 404: return .refused("the ticket or the move no longer exists")
            default: return .refused("HTTP \(status)")
            }
        }
    }

    // MARK: Requests

    /// The values per field key: option ids for a choice, the text for a text field.
    static func transitionBody(_ transition: JiraTransition, values: [String: [String]]) -> [String: Any] {
        var fields: [String: Any] = [:]
        for field in transition.fields {
            guard let chosen = values[field.key], !chosen.isEmpty else { continue }
            switch field.kind {
            case .choice(multiple: true): fields[field.key] = chosen.map { ["id": $0] }
            case .choice(multiple: false): fields[field.key] = ["id": chosen[0]]
            case .text: fields[field.key] = chosen[0]
            case .unsupported: break
            }
        }
        var body: [String: Any] = ["transition": ["id": transition.id]]
        if !fields.isEmpty { body["fields"] = fields }
        return body
    }

    /// The fields still to fill in before the move can be sent.
    static func missing(_ transition: JiraTransition, values: [String: [String]]) -> [JiraTransition.Field] {
        transition.fields.filter { field in
            guard let chosen = values[field.key] else { return true }
            return chosen.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    static func assigneeBody(_ accountID: String?) -> [String: Any] { ["accountId": accountID ?? NSNull()] }

    static func commentBody(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ["body": document(String(trimmed.prefix(commentLimit)))]
    }

    // MARK: Atlassian Document Format

    /// Plain text as a document: a paragraph per blank-line-separated block, line breaks inside it, links as links.
    static func document(_ text: String) -> [String: Any] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let paragraphs = blocks.map { block -> [String: Any] in
            let lines = block.components(separatedBy: "\n")
            let content = lines.enumerated().flatMap { index, line -> [[String: Any]] in
                (index > 0 ? [["type": "hardBreak"]] : []) + inline(line)
            }
            return ["type": "paragraph", "content": content]
        }
        return ["type": "doc", "version": 1, "content": paragraphs]
    }

    private static func inline(_ line: String) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        var rest = Substring(line)
        func plain(_ text: Substring) { if !text.isEmpty { nodes.append(["type": "text", "text": String(text)]) } }
        while let found = rest.firstMatch(of: #/https?://[^\s<>]+/#) {
            var url = String(found.output)
            while let last = url.last, ".,;:!?)\u{201D}\u{2019}".contains(last) { url.removeLast() }
            plain(rest[..<found.range.lowerBound])
            nodes.append(["type": "text", "text": url, "marks": [["type": "link", "attrs": ["href": url]]]])
            rest = rest[found.range.lowerBound...].dropFirst(url.count)
        }
        plain(rest)
        return nodes
    }

    // MARK: Local effect

    static func moved(_ ticket: JiraTicket, to transition: JiraTransition) -> JiraTicket {
        var moved = ticket
        moved.status = transition.status
        moved.category = transition.category ?? ticket.category
        return moved
    }

    static func moved(_ ticket: JiraTicket, status: String, category: JiraStatusCategory?) -> JiraTicket {
        var moved = ticket
        moved.status = status
        moved.category = category
        return moved
    }

    static func assigned(_ ticket: JiraTicket, to person: JiraPerson?) -> JiraTicket {
        var assigned = ticket
        assigned.assignee = person?.name
        assigned.assigneeID = person?.id
        return assigned
    }

    /// A move back to `status` when the ticket's moves now include one that needs nothing filled in.
    static func undo(to status: String, among transitions: [JiraTransition]) -> JiraTransition? {
        transitions.first { $0.status.caseInsensitiveCompare(status) == .orderedSame && $0.fields.isEmpty }
    }
}
