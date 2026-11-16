import Foundation

/// The changes the Jira page makes on a click. Nothing else in the app calls these, and the agents' tools never do.
extension JiraClient {
    func me() async throws -> JiraPerson {
        try JiraLogic.parseMyself(await send(path: JiraLogic.myselfPath))
    }

    func transitions(of key: String) async throws -> [JiraTransition] {
        try JiraWrite.parseTransitions(await send(path: JiraWrite.transitionsPath(key)))
    }

    func move(_ key: String, with transition: JiraTransition, values: [String: [String]] = [:]) async throws {
        _ = try await change(path: JiraWrite.transitionPath(key), method: "POST", body: JiraWrite.transitionBody(transition, values: values))
    }

    /// Assigns the ticket to the person, or to nobody.
    func assign(_ key: String, to person: JiraPerson?) async throws {
        _ = try await change(path: JiraWrite.assigneePath(key), method: "PUT", body: JiraWrite.assigneeBody(person?.id))
    }

    func comment(on key: String, text: String) async throws -> JiraIssue.Comment {
        guard let body = JiraWrite.commentBody(text) else { throw JiraError.refused("the comment is empty") }
        return try JiraWrite.parseComment(await change(path: JiraWrite.commentPath(key), method: "POST", body: body))
    }

    func logWork(on key: String, seconds: Int, started: Date, comment: String) async throws {
        _ = try await change(path: JiraWorklog.path(key), method: "POST", body: JiraWorklog.body(seconds: seconds, started: started, comment: comment))
    }

    func issueTypes(in project: String) async throws -> [JiraIssueType] {
        try JiraCreate.parseTypes(await send(path: JiraCreate.typesPath(project: project)))
    }

    func createForm(in project: String, type: String) async throws -> JiraCreateForm {
        try JiraCreate.parseForm(await send(path: JiraCreate.fieldsPath(project: project, type: type)))
    }

    /// Makes the ticket and returns its key.
    func create(_ body: [String: Any]) async throws -> String {
        try JiraCreate.parseCreated(await change(path: JiraCreate.createPath, method: "POST", body: body))
    }

    func people(matching query: String, assignableTo issueKey: String? = nil) async throws -> [JiraPerson] {
        try JiraWrite.parseUsers(await send(path: JiraWrite.usersPath(query: query, issueKey: issueKey)))
    }

    private func change(path: String, method: String, body: [String: Any]) async throws -> Data {
        let request = JiraLogic.request(site: site, path: path, email: email, token: token, body: body, method: method)
        let (data, status): (Data, Int)
        do { (data, status) = try await transport(request) } catch { throw JiraError.from(error) }
        guard (200..<300).contains(status) else { throw JiraWrite.refusal(status: status, body: data) }
        return data
    }
}
