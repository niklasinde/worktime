import AppKit

/// The live stream of GitHub webhook events from the devops server: one long request that stays open and gets a message per event.
/// It reconnects on its own, resumes from the last event it saw, and the periodic fetch of GitHubModel covers it while it is down.
@MainActor
final class GitHubEventStream: ObservableObject {
    static let shared = GitHubEventStream()
    static let lastIDKey = "githubEventsLastID"

    @Published private(set) var status: GitHubStreamStatus = .off
    @Published private(set) var lastEvent: Date?
    @Published private(set) var hasToken = false
    @Published private(set) var settings: GitHubEventSettings

    var onEvent: ((GitHubEvent) -> Void)?

    private let tokens = TokenStore.githubEvents
    private let defaults = UserDefaults.standard
    private let session = URLSession(configuration: .ephemeral)
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var downSince: Date? = Date()

    private init() {
        settings = GitHubEventSettings(defaults)
        hasToken = tokens.token() != nil
    }

    private var wanted: Bool { settings.enabled && hasToken && settings.streamURL != nil }

    /// Minutes between the timed fetches of GitHubModel now, or nil for none.
    func pollingMinutes(base: Int, now: Date = Date()) -> Int? {
        var current = settings
        current.enabled = wanted
        return GitHubEventLogic.pollingMinutes(base: base, settings: current, streaming: status == .connected,
                                               downFor: downSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func start() {
        hasToken = tokens.token() != nil
        watchWake()
        reconnect()
    }

    func update(_ new: GitHubEventSettings) {
        guard new != settings else { return }
        let restart = new.enabled != settings.enabled || new.streamURL != settings.streamURL || new.backoffCap != settings.backoffCap
        settings = new
        new.save(defaults)
        if restart { reconnect() }
    }

    func save(token: String) throws {
        try tokens.save(token)
        hasToken = tokens.token() != nil
        reconnect()
    }

    func removeToken() {
        tokens.remove()
        hasToken = false
        reconnect()
    }

    /// Opens the stream once with the saved settings and says how it went, without touching the running connection.
    func test() async -> GitHubStreamOutcome {
        guard let token = tokens.token(), let request = settings.request(token: token, lastEventID: nil) else {
            return .failed("Enter an address and a token first")
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            return GitHubStreamOutcome(status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failed("Server unreachable")
        }
    }

    private func reconnect() {
        task?.cancel()
        task = nil
        guard wanted else {
            status = .off
            return
        }
        downSince = downSince ?? Date()
        task = Task { [weak self] in await self?.loop() }
    }

    private func watchWake() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
    }

    private func loop() async {
        var attempt = 0
        while !Task.isCancelled {
            status = .connecting
            let (outcome, connectedFor) = await listen()
            guard !Task.isCancelled else { return }
            downSince = downSince ?? Date()
            attempt = GitHubEventLogic.attempts(after: attempt, connectedFor: connectedFor)
            let seconds = GitHubEventLogic.delay(after: outcome, attempt: max(attempt - 1, 0), cap: TimeInterval(settings.backoffCap),
                                                 jitter: .random(in: 0...1))
            if outcome.isRejection {
                status = .rejected(outcome)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } else {
                await countdown(seconds: seconds, reason: outcome == .connected ? nil : outcome.message)
            }
        }
    }

    private func countdown(seconds: TimeInterval, reason: String?) async {
        var left = Int(seconds.rounded(.up))
        while left > 0, !Task.isCancelled {
            status = .reconnecting(seconds: left, reason: reason)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            left -= 1
        }
    }

    /// Reads the stream until the server ends it or it fails; how it ended, and how long it was open if it did open.
    private func listen() async -> (GitHubStreamOutcome, TimeInterval?) {
        guard let token = tokens.token(), let request = settings.request(token: token, lastEventID: defaults.string(forKey: Self.lastIDKey)) else {
            return (.failed("Address or token missing"), nil)
        }
        var opened: Date?
        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome = GitHubStreamOutcome(status: code)
            let status = RequestLogs.httpStatus(code)
            guard outcome == .connected else {
                RequestLog.shared.record(service: .github, what: "event stream", bytes: 0, started: started, status: status)
                return (outcome, nil)
            }
            opened = Date()
            status = .connected
            downSince = nil
            var parser = SSEParser(lastID: defaults.string(forKey: Self.lastIDKey))
            let lines = SSEParser.lines(of: bytes) { size, error in
                RequestLog.shared.record(service: .github, what: "event stream", bytes: size, started: started, status: (status.text, error != nil))
            }
            for try await line in lines { parser.feed(line + "\n").forEach(receive) }
            return (.connected, opened.map { Date().timeIntervalSince($0) })
        } catch {
            return (.failed(error.localizedDescription), opened.map { Date().timeIntervalSince($0) })
        }
    }

    private func receive(_ message: ServerSentEvent) {
        if let id = message.id { defaults.set(id, forKey: Self.lastIDKey) }
        guard message.event == "github", let event = try? JSONDecoder().decode(GitHubEvent.self, from: Data(message.data.utf8)) else { return }
        lastEvent = Date()
        onEvent?(event)
    }
}
