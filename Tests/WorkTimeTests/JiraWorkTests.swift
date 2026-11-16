import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private final class Sent: @unchecked Sendable {
    var requests: [URLRequest] = []

    var bodies: [[String: Any]] {
        requests.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
    }
}

private func client(answering status: Int = 201, body: String = "{}", sent: Sent) -> JiraClient {
    JiraClient(site: "acme.atlassian.net", email: "me@acme.com", token: "FAKE-JIRA-TOKEN-0000", transport: { request in
        sent.requests.append(request)
        return (Data(body.utf8), status)
    })
}

private final class Box<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func waiting<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

private func ticket(_ key: String, updated: TimeInterval?) -> JiraTicket {
    JiraTicket(key: key, summary: "S", status: "To Do", priority: nil, updated: updated.map { Date(timeIntervalSince1970: $0) })
}

private let createTypesJSON = #"{"issueTypes":[{"id":"1","name":"Bug","subtask":false},{"id":"2","name":"Task","subtask":false},{"id":"3","name":"Sub-task","subtask":true}]}"#

private let createFieldsJSON = """
{"fields":[
 {"fieldId":"summary","required":true,"name":"Summary","schema":{"type":"string"},"hasDefaultValue":false},
 {"fieldId":"description","required":false,"name":"Description","schema":{"type":"string"}},
 {"fieldId":"assignee","required":false,"name":"Assignee","schema":{"type":"user"}},
 {"fieldId":"customfield_10","required":true,"name":"Customer","schema":{"type":"option"},"allowedValues":[{"id":"7","value":"Quiddly"},{"id":"8","value":"Gaia"}]},
 {"fieldId":"fixVersions","required":true,"name":"Fix versions","schema":{"type":"array","items":"version"},"allowedValues":[{"id":"1","name":"2026.11"}]},
 {"fieldId":"priority","required":true,"hasDefaultValue":true,"name":"Priority","schema":{"type":"priority"},"allowedValues":[{"id":"3","name":"Medium"}]},
 {"fieldId":"labels","required":false,"name":"Labels","schema":{"type":"array","items":"string"}}
]}
"""

private func message(_ text: String, author: String? = "Ann", place: String = "#dev") -> SlackMessage {
    SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: place, author: author, text: text, ts: "1763300000.000100", permalink: nil, unread: nil)
}

let jiraWorkTests: [(name: String, run: () throws -> Void)] = [
    ("a ticket counts as changed when Jira updated it after the user looked, not for their own edits a moment before", {
        let now = Date(timeIntervalSince1970: 10_000)
        let seen = JiraSeen(baseline: now)
        check(!seen.isUnseen(ticket("A-1", updated: 9_000)), "older than the baseline")
        check(!seen.isUnseen(ticket("A-1", updated: 10_020)), "within the grace")
        check(seen.isUnseen(ticket("A-1", updated: 10_100)), "after the baseline")
        check(!seen.isUnseen(ticket("A-1", updated: nil)), "no update time")
        let looked = seen.marked("A-1", now: Date(timeIntervalSince1970: 10_500))
        check(!looked.isUnseen(ticket("A-1", updated: 10_100)) && looked.isUnseen(ticket("A-1", updated: 10_600)), "a ticket looked at changes again later")
        check(looked.isUnseen(ticket("A-2", updated: 10_100)), "another ticket is untouched")
        check(looked.unseen([ticket("A-1", updated: 10_600), ticket("A-1", updated: 10_100)]).count == 1, "unseen filters")
        let all = looked.markedAll(now: Date(timeIntervalSince1970: 11_000))
        check(!all.isUnseen(ticket("A-1", updated: 10_600)) && all.seen.isEmpty, "everything seen")
    }),

    ("what the user has seen is remembered, starts at now the first time and drops old entries", {
        let now = Date(timeIntervalSince1970: 100_000_000)
        check(JiraSeen.decode(nil, now: now) == JiraSeen(baseline: now), "first time")
        check(JiraSeen.decode(Data("nonsense".utf8), now: now) == JiraSeen(baseline: now), "unreadable")
        let old = now.addingTimeInterval(-JiraSeen.kept - 100)
        let fresh = now.addingTimeInterval(-100)
        let seen = JiraSeen(baseline: now.addingTimeInterval(-JiraSeen.kept - 1_000), seen: ["OLD-1": old, "NEW-1": fresh])
        let back = JiraSeen.decode(seen.encoded(), now: now)
        check(back.seen.keys.sorted() == ["NEW-1"] && back.baseline == seen.baseline, "round trip drops the old one: \(back.seen.keys.sorted())")
    }),

    ("a logged time is read the way Jira writes it, with an eight-hour day and a five-day week", {
        check(JiraWorklog.seconds("1h 30m") == 5400 && JiraWorklog.seconds("1H30M") == 5400, "hours and minutes")
        check(JiraWorklog.seconds("2d") == 57_600 && JiraWorklog.seconds("1w") == 144_000 && JiraWorklog.seconds("1w 2d") == 201_600, "days and weeks")
        check(JiraWorklog.seconds("45m") == 2700 && JiraWorklog.seconds("1.5h") == 5400 && JiraWorklog.seconds("1,5h") == 5400, "minutes and fractions")
        check(JiraWorklog.seconds("1:30") == 5400 && JiraWorklog.seconds("0:45") == 2700, "clock form")
        check(JiraWorklog.seconds("1h and 30m") == 5400 && JiraWorklog.seconds("1h, 30m") == 5400, "joined")
        check(JiraWorklog.seconds("2 hours 15 minutes") == 8100 && JiraWorklog.seconds("2 days") == 57_600, "words")
        for bad in ["", "90", "abc", "1h x", "0m", "30s", "1:75", "9999w"] { check(JiraWorklog.seconds(bad) == nil, "not a time: \(bad)") }
        check(JiraWorklog.format(5400) == "1h 30m" && JiraWorklog.format(0) == "0m" && JiraWorklog.format(60) == "1m", "format")
        check(JiraWorklog.format(28_800 + 3 * 3600 + 1800) == "1d 3h 30m" && JiraWorklog.format(57_600) == "2d", "days of eight hours")
    }),

    ("logging time sends the seconds, when it started in Jira's format, and the comment as a document", {
        let plus1 = TimeZone(secondsFromGMT: 3600)!
        check(JiraWorklog.started(Date(timeIntervalSince1970: 0), timeZone: plus1) == "1970-01-01T01:00:00.000+0100", "started")
        let body = JiraWorklog.body(seconds: 5400, started: Date(timeIntervalSince1970: 0), comment: " Fixed it ", timeZone: plus1)
        check(body["timeSpentSeconds"] as? Int == 5400 && body["started"] as? String == "1970-01-01T01:00:00.000+0100", "fields")
        check((body["comment"] as? [String: Any])?["type"] as? String == "doc", "comment is a document")
        check(JiraWorklog.body(seconds: 60, started: Date(), comment: "  ")["comment"] == nil, "no empty comment")
        let sent = Sent()
        let done = waiting { try await client(sent: sent).logWork(on: "QDLY-1", seconds: 3600, started: Date(), comment: "") }
        if case .failure(let error) = done { return check(false, "failed \(error)") }
        check(sent.requests[0].httpMethod == "POST" && sent.requests[0].url?.path == "/rest/api/3/issue/QDLY-1/worklog", "request")
        check(sent.bodies[0]["timeSpentSeconds"] as? Int == 3600, "body")
        let refused = waiting { try await client(answering: 400, body: #"{"errorMessages":["Time tracking is off."],"errors":{}}"#, sent: sent).logWork(on: "QDLY-1", seconds: 60, started: Date(), comment: "") }
        if case .failure(let error) = refused { check(error as? JiraError == .refused("Time tracking is off."), "refusal") } else { check(false, "should refuse") }
    }),

    ("the logged time shows with the ticket's facts, and is read from the issue", {
        let json = #"{"key":"A-1","fields":{"summary":"S","status":{"name":"Done"},"timespent":5400}}"#
        let issue = try JiraLogic.parseIssue(Data(json.utf8))
        check(issue.timeSpentSeconds == 5400, "read")
        check(JiraDetail.facts(issue, now: Date()).contains(JiraDetail.Fact(title: "Logged", value: "1h 30m")), "shown")
        check(JiraLogic.issueFields.contains("timespent"), "requested")
        let none = try JiraLogic.parseIssue(Data(#"{"key":"A-1","fields":{"summary":"S","status":{"name":"Done"}}}"#.utf8))
        check(none.timeSpentSeconds == nil && !JiraDetail.facts(none, now: Date()).contains { $0.title == "Logged" }, "nothing logged")
    }),

    ("the types a ticket can be made as skip sub-tasks and start at Task", {
        let types = try JiraCreate.parseTypes(Data(createTypesJSON.utf8))
        check(types.map(\.name) == ["Bug", "Task"], "types \(types.map(\.name))")
        check(JiraCreate.defaultType(among: types)?.name == "Task" && JiraCreate.defaultType(among: [types[0]])?.name == "Bug", "default")
        check(JiraCreate.defaultType(among: []) == nil, "none")
        let newer = try JiraCreate.parseTypes(Data(#"{"values":[{"id":"9","name":"Story"}]}"#.utf8))
        check(newer.map(\.id) == ["9"], "the newer shape")
        check(JiraCreate.typesPath(project: "QDLY").hasPrefix("/rest/api/3/issue/createmeta/QDLY/issuetypes"), "path")
        check(JiraCreate.fieldsPath(project: "QDLY", type: "2").hasPrefix("/rest/api/3/issue/createmeta/QDLY/issuetypes/2"), "fields path")
    }),

    ("what a type requires is asked for, except what the form has its own control for or Jira fills in", {
        let form = try JiraCreate.parseForm(Data(createFieldsJSON.utf8))
        check(form.fields.map(\.key) == ["customfield_10", "fixVersions"], "required extras by name: \(form.fields.map(\.key))")
        check(form.fields[0].kind == .choice(multiple: false) && form.fields[0].options.map(\.name) == ["Quiddly", "Gaia"], "a choice by value")
        check(form.fields[1].kind == .choice(multiple: true), "a list")
        check(form.available.contains("assignee") && form.available.contains("description") && form.available.contains("labels"), "every field on the screen")
        check(!form.needsJira, "all fillable")
        let odd = try JiraCreate.parseForm(Data(#"{"fields":[{"fieldId":"customfield_2","required":true,"name":"Epic","schema":{"type":"any"}}]}"#.utf8))
        check(odd.needsJira, "a field this app cannot fill in")
        check(JiraCreate.canCreate(summary: "S", form: odd, values: [:]) == false, "so it cannot be made here")
    }),

    ("a new ticket needs a summary and its required fields, and puts in only what the screen has", {
        let form = try JiraCreate.parseForm(Data(createFieldsJSON.utf8))
        let task = JiraIssueType(id: "2", name: "Task")
        check(!JiraCreate.canCreate(summary: "  ", form: form, values: ["customfield_10": ["7"], "fixVersions": ["1"]]), "no summary")
        check(!JiraCreate.canCreate(summary: "S", form: form, values: ["customfield_10": ["7"]]), "a field missing")
        check(JiraCreate.missing(form, values: ["customfield_10": [" "], "fixVersions": ["1"]]).map(\.key) == ["customfield_10"], "blank is missing")
        let values = ["customfield_10": ["7"], "fixVersions": ["1"]]
        check(JiraCreate.canCreate(summary: "S", form: form, values: values), "all there")
        let fields = JiraCreate.body(project: "QDLY", type: task, summary: " Do it ", description: "Details", assignee: "557058:abc", form: form, values: values)["fields"] as? [String: Any] ?? [:]
        check((fields["project"] as? [String: String]) == ["key": "QDLY"] && (fields["issuetype"] as? [String: String]) == ["id": "2"], "project and type")
        check(fields["summary"] as? String == "Do it", "summary trimmed")
        check((fields["description"] as? [String: Any])?["type"] as? String == "doc", "description as a document")
        check((fields["assignee"] as? [String: String]) == ["accountId": "557058:abc"], "assignee")
        check((fields["customfield_10"] as? [String: String]) == ["id": "7"] && (fields["fixVersions"] as? [[String: String]]) == [["id": "1"]], "required fields")
        let bare = JiraCreate.body(project: "QDLY", type: task, summary: "S", description: "", assignee: "x", form: JiraCreateForm(), values: [:])["fields"] as? [String: Any] ?? [:]
        check(bare["assignee"] == nil && bare["description"] == nil, "nothing the screen lacks")
    }),

    ("the client reads the create metadata and makes the ticket, returning its key", {
        let sent = Sent()
        let types = waiting { try await client(answering: 200, body: createTypesJSON, sent: sent).issueTypes(in: "QDLY") }
        guard case .success(let found) = types else { return check(false, "types failed \(types)") }
        check(found.count == 2 && sent.requests[0].httpMethod == "GET" && sent.requests[0].url?.path == "/rest/api/3/issue/createmeta/QDLY/issuetypes", "types request")
        let form = waiting { try await client(answering: 200, body: createFieldsJSON, sent: sent).createForm(in: "QDLY", type: "2") }
        guard case .success(let loaded) = form else { return check(false, "form failed \(form)") }
        check(loaded.fields.count == 2 && sent.requests[1].url?.path == "/rest/api/3/issue/createmeta/QDLY/issuetypes/2", "form request")
        let made = waiting { try await client(body: #"{"id":"10","key":"QDLY-9","self":"x"}"#, sent: sent).create(["fields": ["summary": "S"]]) }
        guard case .success(let key) = made else { return check(false, "create failed \(made)") }
        check(key == "QDLY-9" && sent.requests[2].httpMethod == "POST" && sent.requests[2].url?.path == "/rest/api/3/issue", "create request")
        check((sent.bodies.first?["fields"] as? [String: String]) == ["summary": "S"], "create body, the only request with one so far")
        let refused = waiting { try await client(answering: 400, body: #"{"errorMessages":[],"errors":{"summary":"Summary is required."}}"#, sent: sent).create(["fields": ["summary": "S"]]) }
        if case .failure(let error) = refused { check(error as? JiraError == .refused("Summary is required."), "refusal") } else { check(false, "should refuse") }
        check((try? JiraCreate.parseCreated(Data("{}".utf8))) == nil, "an answer without a key")
    }),

    ("a ticket made from a Slack message or a reminder starts from its text and where it came from", {
        let slack = JiraCreate.draft(slack: message("Login fails on test\nsince this morning"), link: URL(string: "https://acme.slack.com/archives/C1/p1763300000000100"))
        check(slack.summary == "Login fails on test" && slack.reminderID == nil, "summary is the first line")
        check(slack.description.contains("since this morning") && slack.description.contains("From Ann in #dev on Slack") && slack.description.contains("https://acme.slack.com/archives/C1/p1763300000000100"), "description \(slack.description)")
        check(JiraCreate.summary(of: String(repeating: "x", count: 400)).count <= JiraCreate.summaryLimit, "long summaries are cut")
        let reminder = Reminder(id: "r1", title: "Ask about the invoice export", notes: "Before Friday", due: nil, created: Date(),
                                source: ReminderSource(kind: .url, reference: "https://example.com/doc", title: "example.com"))
        let draft = JiraCreate.draft(reminder: reminder, jiraSite: "acme.atlassian.net")
        check(draft.summary == "Ask about the invoice export" && draft.reminderID == "r1", "reminder summary")
        check(draft.description == "Before Friday\n\nhttps://example.com/doc", "notes and source: \(draft.description)")
    }),

    ("once its ticket exists a reminder points at it: a bare one by its source, one with a source in its notes", {
        let bare = Reminder(id: "r1", title: "T", due: nil, created: Date())
        let linked = JiraCreate.linking(bare, ticket: "QDLY-9", summary: "Do it", jiraSite: "acme.atlassian.net")
        check(linked.source == .jira(key: "QDLY-9", summary: "Do it") && linked.notes == nil, "source")
        let slack = ReminderSource(kind: .slack, reference: "https://acme.slack.com/archives/C1/p1", title: "Slack #dev")
        let kept = JiraCreate.linking(Reminder(id: "r2", title: "T", notes: "Note", due: nil, created: Date(), source: slack), ticket: "QDLY-9", summary: "Do it", jiraSite: "acme.atlassian.net")
        check(kept.source == slack && kept.notes == "Note\nTicket: https://acme.atlassian.net/browse/QDLY-9", "notes \(String(describing: kept.notes))")
        let same = Reminder(id: "r3", title: "T", due: nil, created: Date(), source: .jira(key: "QDLY-9"))
        check(JiraCreate.linking(same, ticket: "QDLY-9", summary: "Do it", jiraSite: nil) == same, "already pointing there")
    }),

    ("a ticket's links are the reminders, Slack messages and meetings that name its key and no longer key that starts alike", {
        check(JiraLinks.mentions("see qdly-12 now", key: "QDLY-12") && JiraLinks.mentions("QDLY-12", key: "QDLY-12") && JiraLinks.mentions("(QDLY-12).", key: "QDLY-12"), "mentioned")
        check(!JiraLinks.mentions("QDLY-123", key: "QDLY-12") && !JiraLinks.mentions("XQDLY-12", key: "QDLY-12") && !JiraLinks.mentions("QDLY 12", key: "QDLY-12"), "not mentioned")
        let now = Date()
        let reminders = [
            Reminder(id: "a", title: "Review", due: nil, created: now, source: .jira(key: "QDLY-12")),
            Reminder(id: "b", title: "Ask about QDLY-12", due: nil, created: now.addingTimeInterval(1)),
            Reminder(id: "c", title: "Other", notes: "relates to qdly-12", due: nil, created: now.addingTimeInterval(2)),
            Reminder(id: "d", title: "Other ticket", due: nil, created: now, source: .jira(key: "QDLY-123")),
            Reminder(id: "e", title: "Done one QDLY-12", due: nil, created: now, completed: now),
        ]
        check(JiraLinks.reminders("QDLY-12", in: reminders).map(\.id) == ["a", "b", "c"], "reminders \(JiraLinks.reminders("QDLY-12", in: reminders).map(\.id))")
        let messages = [message("about QDLY-12"), message("nothing"), message("QDLY-123 is different")]
        check(JiraLinks.slack("QDLY-12", in: messages).map(\.text) == ["about QDLY-12"], "slack")
        check(JiraLinks.confirms(snippet: "\u{2026}the **QDLY**-**12** export\u{2026}", key: "QDLY-12") || JiraLinks.confirms(snippet: "fix **QDLY-12**", key: "QDLY-12"), "a snippet with highlight marks")
        check(!JiraLinks.confirms(snippet: "**QDLY**-**123**", key: "QDLY-12"), "a longer key")
    }),
]
