import Foundation

/// Making tickets, and what else the app holds about one. Like the other writes, these start from the user's own click.
extension JiraPageModel {
    /// Opens the new ticket form on the Jira page with the draft in it.
    func startTicket(_ draft: JiraCreateDraft) {
        newTicket = draft
        showInWindow?()
    }

    func issueTypes(in project: String) async -> Result<[JiraIssueType], JiraError> {
        await perform { try await $0.issueTypes(in: project) }
    }

    func createForm(in project: String, type: String) async -> Result<JiraCreateForm, JiraError> {
        await perform { try await $0.createForm(in: project, type: type) }
    }

    /// Makes the ticket; on success it is selected on the page, the list is fetched again and the reminder it came from points at it.
    func createTicket(_ body: [String: Any], summary: String, from draft: JiraCreateDraft) async -> Result<String, JiraError> {
        let payload = SendableBody(value: body)
        let result = await perform { try await $0.create(payload.value) }
        if case .success(let key) = result { ticketCreated(key, summary: summary, from: draft) }
        return result
    }

    private func ticketCreated(_ key: String, summary: String, from draft: JiraCreateDraft) {
        newTicket = nil
        if let reminder = draft.reminderID {
            TodoModel.shared.attach(ticket: key, summary: summary, to: reminder, jiraSite: site)
        }
        select(key)
        showNotice("Created \(key)")
        Task { await refresh() }
    }

    /// The meetings that mention the ticket, newest first, found in the transcripts and summaries the app has indexed.
    func loadMeetingLinks(_ key: String) {
        guard let store = GitHubModel.shared.store else { return }
        let hits = (try? store.searchMeetings(key, limit: JiraLinks.meetingLimit * 3)) ?? []
        meetingLinks[key] = hits
            .filter { JiraLinks.confirms(snippet: $0.snippet, key: key) }
            .map { JiraMeetingLink(id: $0.meeting.id, title: $0.meeting.titleOverride ?? $0.meeting.aiTitle ?? "Meeting", date: $0.meeting.created) }
            .sorted { $0.date > $1.date }
            .prefix(JiraLinks.meetingLimit).map { $0 }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (JiraClient) async throws -> T) async -> Result<T, JiraError> {
        guard let client = jira.client() else { return .failure(.notConfigured) }
        return await Task.detached { () -> Result<T, JiraError> in
            do { return .success(try await work(client)) } catch { return .failure(JiraError.from(error)) }
        }.value
    }
}

/// A request body built on the main actor and sent from a task of its own; nothing changes it in between.
private struct SendableBody: @unchecked Sendable {
    let value: [String: Any]
}
