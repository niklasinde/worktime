import Foundation

struct JiraIssueType: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// What a project asks for when a ticket of one type is made: the required fields this app asks the user for, and every field
/// the type's screen has.
struct JiraCreateForm: Equatable, Sendable {
    var fields: [JiraTransition.Field] = []
    var available: Set<String> = []

    var needsJira: Bool { fields.contains { $0.kind == .unsupported } }
}

/// What a new ticket starts from: the text and where it came from, when it is made out of a Slack message or a reminder.
struct JiraCreateDraft: Identifiable, Equatable {
    let id = UUID()
    var project: String?
    var summary = ""
    var description = ""
    /// The reminder the ticket is made from, which points at the ticket once it exists.
    var reminderID: String?
}

/// Making a ticket from a click: the questions put to Jira's create metadata, the request, and the drafts the other pages hand over.
enum JiraCreate {
    static let summaryLimit = 120
    /// Fields the form has its own control for.
    static let handled: Set<String> = ["project", "issuetype", "summary", "description", "reporter", "assignee"]

    static let createPath = "/rest/api/3/issue"

    static func typesPath(project: String) -> String { "/rest/api/3/issue/createmeta/\(project)/issuetypes?maxResults=100" }

    static func fieldsPath(project: String, type: String) -> String {
        "/rest/api/3/issue/createmeta/\(project)/issuetypes/\(type)?maxResults=200"
    }

    // MARK: Answers

    /// The types a ticket can be made as; sub-tasks need a parent, so they are left out.
    static func parseTypes(_ data: Data) throws -> [JiraIssueType] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (object["issueTypes"] ?? object["values"]) as? [[String: Any]] else { throw JiraError.failed("unexpected response") }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String, entry["subtask"] as? Bool != true else { return nil }
            return JiraIssueType(id: id, name: name)
        }
    }

    static func parseForm(_ data: Data) throws -> JiraCreateForm {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (object["fields"] ?? object["values"]) as? [[String: Any]] else { throw JiraError.failed("unexpected response") }
        var form = JiraCreateForm()
        for entry in list {
            guard let key = entry["fieldId"] as? String ?? entry["key"] as? String else { continue }
            form.available.insert(key)
            if !handled.contains(key), let field = JiraWrite.field(key, entry) { form.fields.append(field) }
        }
        form.fields.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return form
    }

    static func parseCreated(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let key = object["key"] as? String else {
            throw JiraError.failed("unexpected response")
        }
        return key
    }

    /// A Task when the project has one, as the type most things are, otherwise the first.
    static func defaultType(among types: [JiraIssueType]) -> JiraIssueType? {
        types.first { $0.name.caseInsensitiveCompare("Task") == .orderedSame } ?? types.first
    }

    // MARK: Request

    /// The fields still to fill in before the ticket can be made.
    static func missing(_ form: JiraCreateForm, values: [String: [String]]) -> [JiraTransition.Field] {
        form.fields.filter { field in
            guard let chosen = values[field.key] else { return true }
            return chosen.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    static func canCreate(summary: String, form: JiraCreateForm, values: [String: [String]]) -> Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !form.needsJira && missing(form, values: values).isEmpty
    }

    /// The assignee goes in only where the type's screen has the field; Jira refuses a field the screen lacks.
    static func body(project: String, type: JiraIssueType, summary: String, description: String, assignee: String?,
                     form: JiraCreateForm, values: [String: [String]]) -> [String: Any] {
        var fields: [String: Any] = ["project": ["key": project], "issuetype": ["id": type.id],
                                     "summary": summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, form.available.contains("description") { fields["description"] = JiraWrite.document(String(text.prefix(JiraWrite.commentLimit))) }
        if let assignee, form.available.contains("assignee") { fields["assignee"] = ["accountId": assignee] }
        for field in form.fields {
            guard let chosen = values[field.key], !chosen.isEmpty else { continue }
            switch field.kind {
            case .choice(multiple: true): fields[field.key] = chosen.map { ["id": $0] }
            case .choice(multiple: false): fields[field.key] = ["id": chosen[0]]
            case .text: fields[field.key] = chosen[0]
            case .unsupported: break
            }
        }
        return ["fields": fields]
    }

    // MARK: Drafts

    /// A ticket out of a Slack message: its first line as the summary and the whole message, who wrote it and the link as the description.
    static func draft(slack message: SlackMessage, link: URL?) -> JiraCreateDraft {
        var lines = [message.text.trimmingCharacters(in: .whitespacesAndNewlines)]
        let from = [message.author, message.place].compactMap { $0 }.filter { !$0.isEmpty }
        if !from.isEmpty { lines.append("From " + from.joined(separator: " in ") + " on Slack") }
        if let link { lines.append(link.absoluteString) }
        return JiraCreateDraft(summary: summary(of: message.text), description: lines.joined(separator: "\n\n"))
    }

    /// A ticket out of a reminder: its title as the summary, its notes and where it came from as the description.
    static func draft(reminder: Reminder, jiraSite: String?) -> JiraCreateDraft {
        var lines: [String] = []
        if let notes = reminder.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { lines.append(notes) }
        if let source = reminder.source, source.kind != .jira { lines.append(source.url(jiraSite: jiraSite)?.absoluteString ?? source.label) }
        return JiraCreateDraft(summary: summary(of: reminder.title), description: lines.joined(separator: "\n\n"), reminderID: reminder.id)
    }

    static func summary(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return ActivityLogic.truncate(line.trimmingCharacters(in: .whitespaces), to: summaryLimit)
    }

    /// The reminder once its ticket exists: one that came from nowhere points at the ticket, one that came from something keeps that
    /// and names the ticket in its notes.
    static func linking(_ reminder: Reminder, ticket key: String, summary: String, jiraSite: String?) -> Reminder {
        var linked = reminder
        guard reminder.source != nil else {
            linked.source = .jira(key: key, summary: summary)
            return linked
        }
        guard reminder.source?.kind != .jira || reminder.source?.reference != key else { return reminder }
        let line = "Ticket: " + (jiraSite.flatMap { JiraLogic.browseURL(site: $0, key: key)?.absoluteString } ?? key)
        linked.notes = [reminder.notes, line].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return linked
    }
}
