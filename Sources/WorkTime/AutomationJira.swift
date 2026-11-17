import Foundation

/// The Jira events: what one automation's search shows, as assignments, new tickets, status changes and comments.
extension Automations {
    static let jiraMax = 50

    /// The JQL one automation polls. The projects it names and its own JQL narrow it; without them a status change or a comment
    /// is one on a ticket assigned to me, reported by me or watched by me.
    static func jiraQuery(_ trigger: AutomationTrigger) -> String {
        let projects = words(trigger.place).filter { $0.wholeMatch(of: #/[A-Za-z][A-Za-z0-9_]*/#) != nil }
        var clauses = projects.isEmpty ? [] : ["project in (\(projects.joined(separator: ", ")))"]
        let involved = "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser())"
        switch trigger.kind {
        case .jiraAssigned: clauses += ["assignee = currentUser()", "statusCategory != Done"]
        case .jiraNew: clauses.append("created >= -2d")
        case .jiraStatus:
            clauses.append("updated >= -2d")
            if projects.isEmpty, trigger.jql.isEmpty { clauses.append(involved) }
        default: clauses += ["updated >= -2d", "(assignee = currentUser() OR reporter = currentUser())"]
        }
        return JQLFilter.compose(jql: trigger.jql, clauses: clauses)
    }

    static func jiraBody(jql: String, kind: AutomationTrigger.Kind) -> [String: Any] {
        var body: [String: Any] = ["jql": jql, "maxResults": jiraMax, "fields": ["summary", "status", "assignee", "created", "updated", "comment"]]
        if kind == .jiraStatus { body["expand"] = "changelog" }
        return body
    }

    /// The events of one kind in a search's answer. `me` is the account id: what I did myself is not an event.
    static func jiraEvents(_ data: Data, kind: AutomationTrigger.Kind, site: String, me: String, now: Date) throws -> [AutomationEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let issues = root["issues"] as? [[String: Any]] else {
            throw JiraError.failed("unexpected response")
        }
        let since = now.addingTimeInterval(-recentWindow)
        func person(_ value: Any?) -> (id: String, name: String) {
            let object = value as? [String: Any]
            return (object?["accountId"] as? String ?? "", object?["displayName"] as? String ?? "Someone")
        }
        return issues.flatMap { issue -> [AutomationEvent] in
            guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any] else { return [] }
            let summary = fields["summary"] as? String ?? ""
            let status = (fields["status"] as? [String: Any])?["name"] as? String ?? ""
            let assignee = person(fields["assignee"])
            let project = key.split(separator: "-").first.map(String.init) ?? key
            let link = JiraLogic.browseURL(site: site, key: key)?.absoluteString
            func event(_ suffix: String?, title: String, text: String, date: Date?, extra: [String: String] = [:]) -> AutomationEvent {
                var values = ["ticket": key, "ticket_title": summary, "status": status, "project": project, "assignee": assignee.name, "url": link ?? ""]
                values.merge(extra) { $1 }
                return AutomationEvent(id: kind.idPrefix + ":" + key + (suffix.map { ":" + $0 } ?? ""), kind: kind, title: title, place: project, text: text,
                                       fields: values, pullRequest: nil, link: link, date: date ?? now)
            }
            switch kind {
            case .jiraAssigned:
                guard assignee.id == me else { return [] }
                return [event(nil, title: "\(key) \(summary)", text: summary, date: (fields["updated"] as? String).flatMap(JiraLogic.date))]
            case .jiraNew:
                return [event(nil, title: "\(key) \(summary)", text: summary, date: (fields["created"] as? String).flatMap(JiraLogic.date))]
            case .jiraStatus:
                let histories = (issue["changelog"] as? [String: Any])?["histories"] as? [[String: Any]] ?? []
                return histories.flatMap { history -> [AutomationEvent] in
                    guard let id = history["id"] as? String, person(history["author"]).id != me,
                          let date = (history["created"] as? String).flatMap(JiraLogic.date), date >= since else { return [] }
                    return (history["items"] as? [[String: Any]] ?? []).filter { $0["field"] as? String == "status" }.map { item in
                        let to = item["toString"] as? String ?? status
                        return event(id, title: "\(key) \(summary)", text: summary, date: date,
                                     extra: ["status": to, "from_status": item["fromString"] as? String ?? ""])
                    }
                }
            default:
                let comments = (fields["comment"] as? [String: Any])?["comments"] as? [[String: Any]] ?? []
                return comments.suffix(20).compactMap { comment -> AutomationEvent? in
                    let author = person(comment["author"])
                    guard let id = comment["id"] as? String, author.id != me, let date = (comment["created"] as? String).flatMap(JiraLogic.date), date >= since else { return nil }
                    let body = JiraLogic.text(comment["body"])
                    return event(id, title: "\(key): \(author.name) commented", text: body, date: date, extra: ["comment": body, "comment_author": author.name])
                }
            }
        }
    }
}
