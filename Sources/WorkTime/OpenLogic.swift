import Foundation

/// Somewhere `open_in_app` or a `worktime://open` link brings the app to.
enum OpenTarget: Equatable {
    case agent(String)
    case ticket(String)
    case pullRequest(String)
    case page(SidebarSection)
}

/// What the `--mcp` process hands the app through the agent inbox to show something; the app answers with a `NoticeReply`.
struct OpenRequest: Codable, Equatable {
    var id: String
    var session: String?
    var ticket: String?
    var pullRequest: String?
    var page: String?
    var source: NoticeSource
    var created: Date
}

enum OpenLinks {
    static let host = "open"

    static func requestName(_ id: String) -> String { id + ".open.json" }

    static func isRequest(_ name: String) -> Bool { name.hasSuffix(".open.json") }

    /// `worktime://open?agent=<key>`, `?ticket=<KEY>`, `?pr=<url>` or `?page=<name>`.
    static func link(_ target: OpenTarget) -> String {
        let (name, value): (String, String) = switch target {
        case .agent(let key): ("agent", key)
        case .ticket(let key): ("ticket", key)
        case .pullRequest(let url): ("pr", url)
        case .page(let section): ("page", section.rawValue)
        }
        return "\(AppURL.scheme)://\(host)?\(name)=\(GitHubClaude.encode(value))"
    }

    static func parse(_ text: String) -> OpenTarget? {
        guard let link = URLComponents(string: text), AppURL.accepts(scheme: link.scheme), link.host?.lowercased() == host,
              let query = link.queryItems, query.count == 1, let value = query[0].value, !value.isEmpty else { return nil }
        switch query[0].name {
        case "agent": return .agent(value)
        case "ticket": return JiraLogic.issueKey(value).map(OpenTarget.ticket)
        case "pr": return GitHubLink.pullRequest(at: value).map { .pullRequest($0.url) }
        case "page": return SidebarSection(rawValue: value).map(OpenTarget.page)
        default: return nil
        }
    }

    static let pages = SidebarSection.allCases.map(\.rawValue)

    /// The request an `open_in_app` call makes: exactly one of session_id, ticket, pr_url and page.
    static func request(_ args: [String: Any], source: NoticeSource, now: Date, id: String = UUID().uuidString) throws -> OpenRequest {
        let named = ["session_id", "ticket", "pr_url", "page"].filter { FilterLogic.text(args, $0) != nil }
        guard named.count == 1 else { throw MCPToolError("Give exactly one of session_id, ticket, pr_url or page.") }
        var request = OpenRequest(id: id, session: nil, ticket: nil, pullRequest: nil, page: nil, source: source, created: now)
        switch named[0] {
        case "session_id": request.session = FilterLogic.text(args, "session_id")
        case "ticket":
            guard let key = FilterLogic.text(args, "ticket").flatMap(JiraLogic.issueKey) else { throw MCPToolError("ticket must be a Jira key like PROJ-123.") }
            request.ticket = key
        case "pr_url":
            guard let target = FilterLogic.text(args, "pr_url").flatMap(GitHubLink.pasted) else { throw MCPToolError("pr_url must be a GitHub pull request address.") }
            request.pullRequest = target.url
        default:
            request.page = try FilterLogic.choice(args, "page", allowed: pages)
        }
        return request
    }

    /// What the app shows for a request, given the agents it knows: the session by its id, the ticket's group, the pull request, or a page.
    static func target(_ request: OpenRequest, agents: [AgentState]) -> Result<OpenTarget, NoticeError> {
        if let session = request.session {
            guard let state = agents.first(where: { $0.sessionID == session }) else { return .failure(NoticeError("No session \(session) in agents_overview.")) }
            return .success(.agent(state.key))
        }
        if let ticket = request.ticket { return .success(.ticket(ticket)) }
        if let url = request.pullRequest { return .success(.pullRequest(url)) }
        if let page = request.page, let section = SidebarSection(rawValue: page) { return .success(.page(section)) }
        return .failure(NoticeError("Nothing to open."))
    }
}
