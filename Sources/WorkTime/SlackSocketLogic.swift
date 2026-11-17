import Foundation

/// A message Slack pushed over the socket, reduced to what the automations need.
struct SlackSocketEvent: Equatable, Sendable {
    let channel: String
    /// `channel`, `group`, `im` or `mpim`.
    let channelType: String?
    let user: String?
    let text: String
    let ts: String
    let threadTS: String?

    var isReply: Bool { threadTS != nil && threadTS != ts }
    var isDirect: Bool { channelType == "im" || channelType == "mpim" }
}

/// One frame from the socket: the ones to answer or act on, and the rest.
enum SlackSocketFrame: Equatable, Sendable {
    case hello
    case disconnect(reason: String)
    case message(envelope: String, event: SlackSocketEvent)
    /// Anything else; when it carries an envelope id Slack waits for an answer to it.
    case other(envelope: String?)
}

enum SlackSocketStatus: Equatable, Sendable {
    case off
    case connecting
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting\u{2026}"
        case .connected: "Connected"
        case .failed(let message): message
        }
    }
}

/// Slack's Socket Mode: the app opens a websocket and Slack pushes the messages the user can see, instead of the app searching for them.
enum SlackSocketLogic {
    static let tokenPrefix = "xapp-"
    static let userEvents = ["message.channels", "message.groups", "message.im", "message.mpim"]
    /// A message with another subtype is an edit, a deletion or a system notice, not something new someone wrote.
    static let subtypes: Set<String> = ["thread_broadcast", "file_share"]
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
    static let heartbeatEvery: TimeInterval = 30
    static let heartbeatLimit: TimeInterval = 80

    static func isAppToken(_ token: String) -> Bool { token.hasPrefix(tokenPrefix) }

    /// How long to wait before the next try after `attempt` failed ones, longer each time up to a minute.
    static func backoff(attempt: Int) -> TimeInterval { delays[min(max(attempt, 0), delays.count - 1)] }

    /// Whether the last answer to a ping is too old to trust the connection.
    static func stale(lastAlive: Date, now: Date) -> Bool { now.timeIntervalSince(lastAlive) > heartbeatLimit }

    static func openRequest(appToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: SlackLogic.base + "apps.connections.open")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        return request
    }

    /// The websocket address from `apps.connections.open`, or what Slack said was wrong with the token.
    static func parseOpen(_ data: Data) throws -> URL {
        do {
            let response = try JSONDecoder().decode(Opened.self, from: SlackLogic.checked(data))
            guard let url = URL(string: response.url), url.scheme == "wss" else { throw SlackError.failed("no socket address") }
            return url
        } catch SlackError.failed(let code) where code == "not_allowed_token_type" || code == "invalid_auth" || code == "missing_scope" {
            throw SlackError.failed("Slack did not accept the app-level token: it starts with xapp- and needs the connections:write scope")
        } catch SlackError.unauthorized {
            throw SlackError.failed("Slack did not accept the app-level token: it starts with xapp- and needs the connections:write scope")
        } catch SlackError.missingScope {
            throw SlackError.failed("The app-level token needs the connections:write scope")
        }
    }

    static func parse(_ text: String) -> SlackSocketFrame {
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { return .other(envelope: nil) }
        switch frame.type {
        case "hello": return .hello
        case "disconnect": return .disconnect(reason: frame.reason ?? "")
        case "events_api":
            guard let envelope = frame.envelope_id else { return .other(envelope: nil) }
            guard let event = frame.payload?.event, event.type == "message", event.bot_id == nil, event.subtype.map(subtypes.contains) ?? true,
                  let channel = event.channel, let ts = event.ts else { return .other(envelope: envelope) }
            return .message(envelope: envelope, event: SlackSocketEvent(channel: channel, channelType: event.channel_type, user: event.user,
                                                                         text: event.text ?? "", ts: ts, threadTS: event.thread_ts))
        default: return .other(envelope: frame.envelope_id)
        }
    }

    /// The answer Slack waits for after every envelope, or it sends it again.
    static func acknowledgement(_ envelope: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: ["envelope_id": envelope])) ?? Data(), as: UTF8.self)
    }

    /// Whether someone else wrote it: the user's own messages start nothing.
    static func isFromOthers(_ event: SlackSocketEvent, me: SlackIdentity) -> Bool {
        event.user != nil && event.user != me.userID
    }

    // MARK: Setup

    /// A Slack app for WorkTime, ready to paste under Create New App, From a manifest: the sign-in's scopes, no write scope, and
    /// Socket Mode with the message events on behalf of the user.
    static func manifest(redirect: String = SlackLogic.redirect, scopes: [String] = SlackLogic.scopes) -> String {
        let document: [String: Any] = [
            "display_information": ["name": "WorkTime"],
            "oauth_config": ["redirect_urls": [redirect], "scopes": ["user": scopes]],
            "settings": [
                "event_subscriptions": ["user_events": userEvents],
                "org_deploy_enabled": false,
                "socket_mode_enabled": true,
                "token_rotation_enabled": true,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static let steps = [
        "Open api.slack.com/apps. Use the app you already signed in with, or choose Create New App, From a manifest, and paste the manifest below.",
        "Under Socket Mode, turn Enable Socket Mode on.",
        "Under Basic Information, App-Level Tokens, generate one with the connections:write scope, and paste it above.",
        "Under Event Subscriptions, turn events on and add these under Subscribe to events on behalf of users: \(userEvents.joined(separator: ", ")).",
        "Reinstall the app when Slack asks, then sign in with Slack again in WorkTime if it asks you to.",
    ]

    private struct Opened: Decodable { let url: String }

    private struct Frame: Decodable {
        let type: String?
        let envelope_id: String?
        let reason: String?
        let payload: Payload?

        struct Payload: Decodable { let event: Event? }

        struct Event: Decodable {
            let type: String?
            let subtype: String?
            let bot_id: String?
            let channel: String?
            let channel_type: String?
            let user: String?
            let text: String?
            let ts: String?
            let thread_ts: String?
        }
    }
}
