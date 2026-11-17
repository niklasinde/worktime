import AppKit

/// The websocket to Slack's Socket Mode while an automation waits for Slack messages: Slack pushes each message as it is written.
/// It reconnects on its own, and the search the automations also run covers whatever was missed meanwhile.
@MainActor
final class SlackSocket: ObservableObject {
    static let shared = SlackSocket()

    @Published private(set) var status: SlackSocketStatus = .off
    @Published private(set) var lastEvent: Date?
    @Published private(set) var hasToken = false

    var onEvent: ((SlackSocketEvent) -> Void)?
    /// Called after every (re)connection, to look for what was missed while it was down.
    var onConnected: (() -> Void)?
    /// Called when the token is saved or removed, so the connection follows at once.
    var onTokenChanged: (() -> Void)?
    var transport: SlackTransport = SlackClient.urlSession

    private let tokens = TokenStore.slackApp
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var observer: NSObjectProtocol?

    private init() { hasToken = tokens.token() != nil }

    var running: Bool { task != nil }

    /// Starts the connection when it is wanted and a token is saved, stops it when not.
    func setWanted(_ wanted: Bool) {
        hasToken = tokens.token() != nil
        guard wanted, hasToken else {
            guard task != nil else { return }
            stop()
            return
        }
        guard task == nil else { return }
        watchWake()
        task = Task { [weak self] in await self?.loop() }
    }

    func save(token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SlackSocketLogic.isAppToken(trimmed) else { throw SlackError.failed("An app-level token starts with xapp-.") }
        try tokens.save(trimmed)
        hasToken = true
        stop()
        onTokenChanged?()
    }

    func removeToken() {
        tokens.remove()
        hasToken = false
        stop()
        onTokenChanged?()
    }

    /// Asks Slack for a connection address with the saved token, without keeping the connection.
    func test() async -> Result<Void, SlackError> {
        guard let token = tokens.token() else { return .failure(.notConfigured) }
        do {
            _ = try await open(token: token)
            return .success(())
        } catch {
            return .failure(SlackError.from(error))
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .off
    }

    private func watchWake() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.socket?.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func open(token: String) async throws -> URL {
        let (data, status, retryAfter): (Data, Int, String?)
        do { (data, status, retryAfter) = try await transport(SlackSocketLogic.openRequest(appToken: token)) } catch { throw SlackError.from(error) }
        if status == 429 { throw SlackError.rateLimited(retryAfter: SlackLogic.retryAfter(retryAfter)) }
        guard (200..<300).contains(status) else { throw SlackError.failed("HTTP \(status)") }
        return try SlackSocketLogic.parseOpen(data)
    }

    private func loop() async {
        var attempt = 0
        while !Task.isCancelled {
            guard let token = tokens.token() else { return stop() }
            status = .connecting
            do {
                let url = try await open(token: token)
                try await listen(to: url, attempt: &attempt)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status = .failed(SlackError.from(error).message)
            }
            guard !Task.isCancelled else { return }
            let wait = SlackSocketLogic.backoff(attempt: attempt)
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Reads the frames until Slack asks for a new connection or this one fails.
    private func listen(to url: URL, attempt: inout Int) async throws {
        let ws = URLSession.shared.webSocketTask(with: url)
        let heartbeat = Heartbeat()
        socket = ws
        ws.resume()
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SlackSocketLogic.heartbeatEvery * 1_000_000_000))
                ws.sendPing { error in if error == nil { heartbeat.alive() } }
                if SlackSocketLogic.stale(lastAlive: heartbeat.last, now: Date()) { ws.cancel(with: .goingAway, reason: nil) }
            }
        }
        defer {
            watchdog.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            if socket === ws { socket = nil }
        }
        while true {
            let message = try await ws.receive()
            heartbeat.alive()
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            switch SlackSocketLogic.parse(text) {
            case .hello:
                status = .connected
                attempt = 0
                onConnected?()
            case .disconnect:
                return
            case .message(let envelope, let event):
                try await ws.send(.string(SlackSocketLogic.acknowledgement(envelope)))
                lastEvent = Date()
                onEvent?(event)
            case .other(let envelope):
                if let envelope { try await ws.send(.string(SlackSocketLogic.acknowledgement(envelope))) }
            }
        }
    }
}

/// When the connection last answered, read by the watchdog off the main actor.
private final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date()

    var last: Date { lock.withLock { time } }
    func alive() { lock.withLock { time = Date() } }
}
