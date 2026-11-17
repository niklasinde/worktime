import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let fakeToken = "FAKE-JIRA-TOKEN-0000"

private final class Sent: @unchecked Sendable {
    var requests: [URLRequest] = []

    var bodies: [[String: Any]] {
        requests.compactMap { try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any] }
    }
}

private func writeClient(answering status: Int = 204, body: String = "", sent: Sent) -> JiraClient {
    JiraClient(site: "acme.atlassian.net", email: "me@acme.com", token: fakeToken, transport: { request in
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

private let transitionsJSON = """
{"transitions":[
 {"id":"11","name":"Start progress","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"fields":{}},
 {"id":"31","name":"Done","to":{"name":"Done","statusCategory":{"key":"done"}},"hasScreen":true,"fields":{
   "resolution":{"required":true,"name":"Resolution","schema":{"type":"resolution"},"allowedValues":[{"id":"10000","name":"Done"},{"id":"10001","name":"Won't do"}]},
   "fixVersions":{"required":true,"name":"Fix versions","schema":{"type":"array","items":"version"},"allowedValues":[{"id":"7","name":"2026.11"},{"id":"8","name":"2026.12"}]},
   "comment":{"required":false,"name":"Comment","schema":{"type":"string"}},
   "labels":{"required":true,"hasDefaultValue":true,"name":"Labels","schema":{"type":"array","items":"string"}}}},
 {"id":"41","name":"Hand over","to":{"name":"Waiting"},"fields":{
   "customfield_1":{"required":true,"name":"Reason","schema":{"type":"string"}},
   "assignee":{"required":true,"name":"Assignee","schema":{"type":"user"}}}}
]}
"""

let jiraWriteTests: [(name: String, run: () throws -> Void)] = [
    ("a ticket's moves are parsed with the fields Jira requires: choices, text and what this app cannot fill in", {
        let moves = try JiraWrite.parseTransitions(Data(transitionsJSON.utf8))
        check(moves.map(\.name) == ["Start progress", "Done", "Hand over"], "names")
        check(moves[0].status == "In Progress" && moves[0].category == .inProgress && moves[0].fields.isEmpty, "a plain move")
        let done = moves[1]
        check(done.status == "Done" && done.category == .done, "target")
        check(done.fields.map(\.key) == ["fixVersions", "resolution"], "required fields without a default, by name: \(done.fields.map(\.key))")
        check(done.fields[0].kind == .choice(multiple: true) && done.fields[1].kind == .choice(multiple: false), "kinds")
        check(done.fields[1].options == [.init(id: "10000", name: "Done"), .init(id: "10001", name: "Won't do")], "options")
        check(!done.needsJira, "done is done here")
        let handOver = moves[2]
        check(handOver.fields.map(\.kind) == [.unsupported, .text] && handOver.needsJira, "a user field is left to Jira \(handOver.fields.map(\.kind))")
        check(handOver.status == "Waiting" && handOver.category == nil, "no category")
        check((try? JiraWrite.parseTransitions(Data("nope".utf8))) == nil, "bad answer")
    }),

    ("a move is sent with its id and the chosen values only, and what is still missing is known", {
        let moves = try JiraWrite.parseTransitions(Data(transitionsJSON.utf8))
        let done = moves[1]
        let body = JiraWrite.transitionBody(done, values: ["resolution": ["10000"], "fixVersions": ["7", "8"], "unrelated": ["x"]])
        check((body["transition"] as? [String: String]) == ["id": "31"], "transition")
        let fields = body["fields"] as? [String: Any] ?? [:]
        check((fields["resolution"] as? [String: String]) == ["id": "10000"], "resolution is an object with an id")
        check((fields["fixVersions"] as? [[String: String]]) == [["id": "7"], ["id": "8"]], "versions are a list")
        check(fields["unrelated"] == nil, "other keys are left out")
        check(JiraWrite.transitionBody(moves[0], values: [:]).keys.sorted() == ["transition"], "no fields, no fields key")
        check(JiraWrite.missing(done, values: ["resolution": ["10000"]]).map(\.key) == ["fixVersions"], "version missing")
        check(JiraWrite.missing(done, values: ["resolution": ["10000"], "fixVersions": ["7"]]).isEmpty, "all there")
        check(JiraWrite.missing(done, values: ["resolution": [" "], "fixVersions": []]).count == 2, "blank is missing")
        let text = JiraWrite.transitionBody(moves[2], values: ["customfield_1": ["Waiting for the customer"]])
        check((text["fields"] as? [String: Any])?["customfield_1"] as? String == "Waiting for the customer", "text")
    }),

    ("a comment becomes a document: paragraphs, line breaks and links, and nothing for an empty text", {
        check(JiraWrite.commentBody("  \n ") == nil, "empty")
        let document = JiraWrite.document("Hej!\nSe https://acme.atlassian.net/browse/ACME-1, tack.\n\nNew paragraph")
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        check(document["type"] as? String == "doc" && document["version"] as? Int == 1, "doc")
        let paragraphs = document["content"] as? [[String: Any]] ?? []
        check(paragraphs.count == 2 && paragraphs.allSatisfy { $0["type"] as? String == "paragraph" }, "two paragraphs")
        let first = paragraphs[0]["content"] as? [[String: Any]] ?? []
        check(first.map { $0["type"] as? String } == ["text", "hardBreak", "text", "text", "text"], "text, break, text, link, text: \(first.map { $0["type"] ?? "" })")
        check(first[2]["text"] as? String == "Se ", "before the link")
        check(first[3]["text"] as? String == "https://acme.atlassian.net/browse/ACME-1", "the link without the comma")
        let marks = first[3]["marks"] as? [[String: Any]] ?? []
        check(marks.first?["type"] as? String == "link" && (marks.first?["attrs"] as? [String: String])?["href"] == "https://acme.atlassian.net/browse/ACME-1", "link mark")
        check(first[4]["text"] as? String == ", tack.", "after the link")
        check(json.contains("\"New paragraph\""), json)
        let body = JiraWrite.commentBody("Hello")
        check((body?["body"] as? [String: Any])?["type"] as? String == "doc", "wrapped as body")
        let back = JiraLogic.text(document)
        check(back.contains("Hej!") && back.contains("New paragraph"), "reads back as text: \(back)")
    }),

    ("assigning sends the account id, or null for nobody, and people are searched by name for a ticket or for the filter", {
        check((JiraWrite.assigneeBody("557058:abc")["accountId"] as? String) == "557058:abc", "person")
        check(JiraWrite.assigneeBody(nil)["accountId"] is NSNull, "nobody")
        check(JiraWrite.usersPath(query: "anna b") == "/rest/api/3/user/search?query=anna%20b&maxResults=20", JiraWrite.usersPath(query: "anna b"))
        check(JiraWrite.usersPath(query: "a&b", issueKey: "ACME-1") == "/rest/api/3/user/assignable/search?issueKey=ACME-1&query=a%26b&maxResults=20",
              JiraWrite.usersPath(query: "a&b", issueKey: "ACME-1"))
        let users = try JiraWrite.parseUsers(Data(#"[{"accountId":"1","displayName":"Anna Berg","active":true,"accountType":"atlassian"},{"accountId":"2","displayName":"Old","active":false},{"accountId":"3","displayName":"Bot","active":true,"accountType":"app"},{"accountId":"4","displayName":"Bo"}]"#.utf8))
        check(users == [JiraPerson(id: "1", name: "Anna Berg"), JiraPerson(id: "4", name: "Bo")], "active people only \(users)")
        let me = try JiraLogic.parseMyself(Data(#"{"accountId":"99","displayName":"Niklas Inde"}"#.utf8))
        check(me == JiraPerson(id: "99", name: "Niklas Inde"), "myself")
        let comment = try JiraWrite.parseComment(Data(#"{"id":"1","author":{"displayName":"Niklas Inde"},"created":"2026-11-16T15:00:00.000+0100","body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Done."}]}]}}"#.utf8))
        check(comment.author == "Niklas Inde" && comment.body == "Done." && comment.created != nil, "comment")
    }),

    ("Jira's refusals are told plainly: field errors, permissions, a ticket that is gone", {
        check(JiraWrite.refusal(status: 400, body: Data(#"{"errorMessages":[],"errors":{"resolution":"Resolution is required."}}"#.utf8)) == .refused("Resolution is required."), "field error")
        check(JiraWrite.refusal(status: 400, body: Data(#"{"errorMessages":["Transition is not valid."],"errors":{}}"#.utf8)) == .refused("Transition is not valid."), "message")
        check(JiraWrite.refusal(status: 403, body: Data()) == .refused("this account may not change that ticket"), "403")
        check(JiraWrite.refusal(status: 404, body: Data()) == .refused("the ticket or the move no longer exists"), "404")
        check(JiraWrite.refusal(status: 401, body: Data()) == .unauthorized && JiraWrite.refusal(status: 429, body: Data()) == .rateLimited, "auth and rate")
        check(JiraWrite.refusal(status: 500, body: Data()) == .refused("HTTP 500"), "500")
        check(JiraError.refused("x").message == "Jira refused: x", "message text")
    }),

    ("the client sends moves, assignments and comments with the right method, path and body, and says what Jira refused", {
        let moves = try JiraWrite.parseTransitions(Data(transitionsJSON.utf8))
        let sent = Sent()
        let sentMove = waiting { try await writeClient(sent: sent).move("ACME-1", with: moves[1], values: ["resolution": ["10000"], "fixVersions": ["7"]]) }
        if case .failure(let error) = sentMove { return check(false, "move failed \(error)") }
        check(sent.requests[0].httpMethod == "POST" && sent.requests[0].url?.path == "/rest/api/3/issue/ACME-1/transitions", "move request")
        check(sent.requests[0].value(forHTTPHeaderField: "Authorization") == JiraLogic.authorization(email: "me@acme.com", token: fakeToken), "auth")
        check((sent.bodies[0]["transition"] as? [String: String]) == ["id": "31"], "move body")

        let sentAssign = waiting { try await writeClient(sent: sent).assign("ACME-1", to: JiraPerson(id: "557058:abc", name: "Anna")) }
        if case .failure(let error) = sentAssign { return check(false, "assign failed \(error)") }
        check(sent.requests[1].httpMethod == "PUT" && sent.requests[1].url?.path == "/rest/api/3/issue/ACME-1/assignee", "assign request")
        check(sent.bodies[1]["accountId"] as? String == "557058:abc", "assign body")
        _ = waiting { try await writeClient(sent: sent).assign("ACME-1", to: nil) }
        check(sent.bodies[2]["accountId"] is NSNull, "unassign sends null")

        let posted = waiting { try await writeClient(answering: 201, body: #"{"author":{"displayName":"Niklas"},"created":"2026-11-16T15:00:00.000+0100","body":"ok"}"#, sent: sent).comment(on: "ACME-1", text: "Hello") }
        guard case .success(let comment) = posted else { return check(false, "comment failed \(posted)") }
        check(sent.requests[3].httpMethod == "POST" && sent.requests[3].url?.path == "/rest/api/3/issue/ACME-1/comment", "comment request")
        check(comment.body == "ok", "comment answer")
        let empty = waiting { try await writeClient(sent: sent).comment(on: "ACME-1", text: "  ") }
        if case .failure(let error) = empty { check(error as? JiraError == .refused("the comment is empty"), "empty refused") } else { check(false, "empty went out") }
        check(sent.requests.count == 4, "an empty comment is not sent")

        let refused = waiting { try await writeClient(answering: 400, body: #"{"errorMessages":[],"errors":{"resolution":"Resolution is required."}}"#, sent: sent).move("ACME-1", with: moves[0]) }
        if case .failure(let error) = refused { check(error as? JiraError == .refused("Resolution is required."), "refusal \(error)") } else { check(false, "should refuse") }
    }),

    ("a ticket moves and is assigned on the page at once, and the way back is a move to where it was that asks for nothing", {
        let ticket = JiraTicket(key: "A-1", summary: "S", status: "To Do", priority: nil, updated: nil, assignee: "Old", assigneeID: "1", category: .todo)
        let moves = try JiraWrite.parseTransitions(Data(transitionsJSON.utf8))
        let moved = JiraWrite.moved(ticket, to: moves[0])
        check(moved.status == "In Progress" && moved.category == .inProgress && moved.summary == "S", "moved")
        check(JiraWrite.moved(ticket, to: moves[2]).category == .todo, "no category keeps the old one")
        let assigned = JiraWrite.assigned(ticket, to: JiraPerson(id: "2", name: "New"))
        check(assigned.assignee == "New" && assigned.assigneeID == "2" && JiraWrite.assigned(ticket, to: nil).assignee == nil, "assigned")
        let back = [JiraTransition(id: "21", name: "Stop", status: "To Do", category: .todo, fields: []),
                    JiraTransition(id: "22", name: "Reopen", status: "To Do", category: .todo, fields: [.init(key: "x", name: "X", kind: .text, options: [])])]
        check(JiraWrite.undo(to: "to do", among: back)?.id == "21", "the one without fields")
        check(JiraWrite.undo(to: "Done", among: back) == nil && JiraWrite.undo(to: "To Do", among: [back[1]]) == nil, "none to go back with")
    }),
]
