import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let pull = "https://github.com/acme/orbit.api/pull/12"
private let at = Date(timeIntervalSince1970: 1_792_300_000)

private func event(_ name: String, action: String? = nil, repo: String? = "acme/orbit.api", number: Int? = 12, link: String? = nil) -> GitHubEvent {
    GitHubEvent(event: name, action: action, repo: repo, number: number, htmlURL: link)
}

private func settings(_ change: (inout GitHubEventSettings) -> Void = { _ in }) -> GitHubEventSettings {
    var settings = GitHubEventSettings()
    settings.enabled = true
    change(&settings)
    return settings
}

let githubEventTests: [(name: String, run: () throws -> Void)] = [
    ("github events: the parser keeps ids, joins data lines and ignores comments", {
        var parser = SSEParser()
        let messages = parser.feed(": hi\nid: 7\nevent: github\ndata: {\"a\":1}\ndata: more\n\n: beat\n\ndata: x\n\n")
        check(messages == [ServerSentEvent(event: "github", data: "{\"a\":1}\nmore", id: "7"), ServerSentEvent(event: nil, data: "x", id: "7")], "\(messages)")
        check(parser.lastID == "7", "the last id is kept")
        var resumed = SSEParser(lastID: "5")
        check(resumed.feed("data: z") .isEmpty && resumed.feed("\r\n\r\nid:9\ndata:\r\n\r\n") == [ServerSentEvent(event: nil, data: "z", id: "5"),
              ServerSentEvent(event: nil, data: "", id: "9")], "resumed, CRLF, no space")
    }),

    ("github events: an event is decoded leniently and names its pull request", {
        let json = #"{"event":"pull_request","action":"closed","repo":"acme/orbit.api","sender":"anna","delivery_id":"d1","number":12,"title":"T","html_url":"https://github.com/acme/orbit.api/pull/12","state":"closed","merged":true,"draft":false,"head_sha":null,"created":1792300000,"extra":[1]}"#
        let decoded = try? JSONDecoder().decode(GitHubEvent.self, from: Data(json.utf8))
        check(decoded?.event == "pull_request" && decoded?.merged == true && decoded?.number == 12 && decoded?.deliveryID == "d1", "\(String(describing: decoded))")
        check(decoded?.isClosing == true && decoded?.pullRequestURL == pull, "closing, url")
        check(event("check_run", repo: nil, number: nil, link: pull + "#issuecomment-5").pullRequestURL == pull, "from the link without its fragment")
        check(event("issue_comment", repo: nil, number: nil, link: "https://github.com/acme/orbit.api/issues/3").pullRequestURL == nil, "an issue is no pull request")
        check(event("status", repo: nil, number: nil).pullRequestURL == nil, "nothing to match")
        let odd = try? JSONDecoder().decode(GitHubEvent.self, from: Data(#"{"number":"x","merged":"no","event":5}"#.utf8))
        check(odd == GitHubEvent(), "wrong types become missing: \(String(describing: odd))")
    }),

    ("github events: the address carries the repositories and event types of the settings", {
        let all = settings().streamURL?.absoluteString ?? ""
        check(all == "https://devops.indepower.se/api/github_events/stream?events=pull_request,pull_request_review,pull_request_review_comment,issue_comment,check_run,check_suite,workflow_run,status", all)
        let narrowed = settings { $0.repos = ["acme/orbit.api", "acme/web"]; $0.kinds = [.checks]; $0.url = " https://x.test/s?since=1&repos=old " }
        let items = URLComponents(url: narrowed.streamURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(items == [URLQueryItem(name: "since", value: "1"), URLQueryItem(name: "repos", value: "acme/orbit.api,acme/web"),
                        URLQueryItem(name: "events", value: "check_run,check_suite,workflow_run,status")], "\(items)")
        check(settings { $0.kinds = [] }.streamURL == nil && settings { $0.url = "ftp://x" }.streamURL == nil && settings { $0.url = "" }.streamURL == nil, "no address")
        let request = settings().request(token: "tok", lastEventID: "42")
        check(request?.value(forHTTPHeaderField: "Authorization") == "Bearer tok" && request?.value(forHTTPHeaderField: "Last-Event-ID") == "42"
              && request?.value(forHTTPHeaderField: "Accept") == "text/event-stream", "headers")
        check(settings().request(token: "t", lastEventID: nil)?.value(forHTTPHeaderField: "Last-Event-ID") == nil, "no id yet")
        check(GitHubEventSettings.parseRepos("acme/a, acme/b  junk\nacme/c,") == ["acme/a", "acme/b", "acme/c"], "repos parsed")
    }),

    ("github events: settings are stored with defaults and read back", {
        let suite = UserDefaults(suiteName: "github-events-tests")!
        suite.removePersistentDomain(forName: "github-events-tests")
        let fresh = GitHubEventSettings(suite)
        check(fresh == GitHubEventSettings() && !fresh.enabled && fresh.streamMinutes == 10 && fresh.fallbackMinutes == 0
              && fresh.downSeconds == 60 && fresh.backoffCap == 60 && fresh.kinds.count == 4, "defaults")
        var changed = settings { $0.repos = ["acme/a"]; $0.kinds = [.reviews]; $0.streamMinutes = 0; $0.fallbackMinutes = 5; $0.downSeconds = 120; $0.backoffCap = 300 }
        changed.url = "https://x.test/s"
        changed.save(suite)
        check(GitHubEventSettings(suite) == changed, "round trip")
        suite.set(7, forKey: GitHubEventSettings.streamMinutesKey)
        check(GitHubEventSettings(suite).streamMinutes == 10, "a value that is no choice falls back")
        suite.removePersistentDomain(forName: "github-events-tests")
    }),

    ("github events: the backoff doubles to the cap, spreads and resets after a healthy connection", {
        check(GitHubEventLogic.backoff(attempt: 0, cap: 60, jitter: 0.5) == 1, "1 s first")
        check([1, 2, 3, 4].map { GitHubEventLogic.backoff(attempt: $0, cap: 60, jitter: 0.5) } == [2, 4, 8, 16], "doubles")
        check(GitHubEventLogic.backoff(attempt: 10, cap: 60, jitter: 1) == 60 && GitHubEventLogic.backoff(attempt: 99, cap: 30, jitter: 1) == 30, "capped")
        check(GitHubEventLogic.backoff(attempt: 3, cap: 60, jitter: 0) == 6 && GitHubEventLogic.backoff(attempt: 3, cap: 60, jitter: 1) == 10, "jitter")
        check(GitHubEventLogic.attempts(after: 3, connectedFor: nil) == 4 && GitHubEventLogic.attempts(after: 3, connectedFor: 5) == 4
              && GitHubEventLogic.attempts(after: 3, connectedFor: 3300) == 0, "reset after a healthy stream")
        check(GitHubEventLogic.delay(after: .wrongToken, attempt: 0, cap: 60, jitter: 0) == 300
              && GitHubEventLogic.delay(after: .noServerToken, attempt: 5, cap: 60, jitter: 0) == 300
              && GitHubEventLogic.delay(after: .tooManyStreams, attempt: 0, cap: 60, jitter: 0.5) == 1, "a rejection waits five minutes")
    }),

    ("github events: statuses are told apart", {
        check(GitHubStreamOutcome(status: 200) == .connected && GitHubStreamOutcome(status: 401) == .wrongToken
              && GitHubStreamOutcome(status: 503) == .noServerToken && GitHubStreamOutcome(status: 429) == .tooManyStreams
              && GitHubStreamOutcome(status: 502) == .failed("HTTP 502"), "classified")
        check(GitHubStreamStatus.reconnecting(seconds: 8, reason: nil).label == "Reconnecting in 8 s"
              && GitHubStreamStatus.rejected(.wrongToken).label == "Wrong token"
              && GitHubStreamStatus.rejected(.noServerToken).label == "Server has no token set", "labels")
    }),

    ("github events: an event refreshes the tracked pull request it is about, a closing one is marked", {
        let tracked: Set<String> = [pull]
        check(GitHubEventLogic.action(for: event("check_run"), settings: settings(), tracked: tracked) == GitHubEventAction(url: pull, closing: false), "check")
        check(GitHubEventLogic.action(for: event("pull_request", action: "closed"), settings: settings(), tracked: tracked)
              == GitHubEventAction(url: pull, closing: true), "closed")
        check(GitHubEventLogic.action(for: event("pull_request", action: "opened"), settings: settings(), tracked: tracked)?.closing == false, "opened is no closing")
        check(GitHubEventLogic.action(for: event("check_run", number: 99), settings: settings(), tracked: tracked) == nil, "not tracked")
        check(GitHubEventLogic.action(for: event("push"), settings: settings(), tracked: tracked) == nil
              && GitHubEventLogic.action(for: event(""), settings: settings(), tracked: tracked) == nil, "other events")
        check(GitHubEventLogic.action(for: event("status"), settings: settings { $0.kinds = [.pullRequests] }, tracked: tracked) == nil, "type switched off")
        check(GitHubEventLogic.action(for: event("pull_request_review_comment"), settings: settings { $0.kinds = [.reviews] }, tracked: tracked) != nil, "type on")
        check(GitHubEventLogic.action(for: event("check_run"), settings: settings { $0.repos = ["acme/other"] }, tracked: tracked) == nil
              && GitHubEventLogic.action(for: event("check_run"), settings: settings { $0.repos = ["ACME/Orbit.API"] }, tracked: tracked) != nil, "repos filter, any case")
    }),

    ("github events: polling is slow while the stream is up and fast again after it was down too long", {
        let on = settings()
        func minutes(_ s: GitHubEventSettings, streaming: Bool, down: TimeInterval = 0) -> Int? {
            GitHubEventLogic.pollingMinutes(base: 5, settings: s, streaming: streaming, downFor: down)
        }
        check(minutes(on, streaming: true) == 10, "connected")
        check(minutes(on, streaming: false, down: 59) == 10, "a short gap")
        check(minutes(on, streaming: false, down: 60) == 5, "down for the grace time")
        check(minutes(settings { $0.fallbackMinutes = 15 }, streaming: false, down: 600) == 15, "a set fallback")
        check(minutes(settings { $0.streamMinutes = 0 }, streaming: true) == nil, "none while connected")
        check(minutes(GitHubEventSettings(), streaming: true) == 5, "stream off keeps the old interval")
        check(minutes(settings { $0.downSeconds = 300 }, streaming: false, down: 200) == 10, "a longer grace")
        check(GitHubEventLogic.isDue(last: at, now: at.addingTimeInterval(600), minutes: 10) && !GitHubEventLogic.isDue(last: at, now: at.addingTimeInterval(599), minutes: 10)
              && !GitHubEventLogic.isDue(last: at, now: at.addingTimeInterval(9999), minutes: nil), "due")
    }),

    ("github events: bursts for one pull request share a refresh after the window", {
        var pending = PendingRefreshes()
        let other = "https://github.com/acme/orbit.api/pull/13"
        pending.add(pull, now: at)
        pending.add(pull, now: at.addingTimeInterval(1.5))
        pending.add(other, now: at.addingTimeInterval(1.5))
        check(pending.take(now: at.addingTimeInterval(1.9)).isEmpty, "not yet")
        check(pending.take(now: at.addingTimeInterval(2)) == [pull], "the first comes after the window, once")
        check(pending.take(now: at.addingTimeInterval(3.5)) == [other] && pending.isEmpty, "the other follows")
        check(pending.take(now: at.addingTimeInterval(9)).isEmpty, "nothing twice")
    }),
]
