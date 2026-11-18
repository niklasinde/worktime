import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let start = Date(timeIntervalSince1970: 1_792_300_000)

private func entry(_ service: RequestService = .github, bytes: Int = 100, at offset: TimeInterval = 0, failed: Bool = false) -> RequestEntry {
    RequestEntry(date: start.addingTimeInterval(offset), service: service, what: "gh pr list", status: failed ? "HTTP 502" : "ok", failed: failed, bytes: bytes, duration: 0.4)
}

let requestLogTests: [(name: String, run: () throws -> Void)] = [
    ("request log keeps the newest fifty and counts every request", {
        var state = RequestLogState()
        for index in 0..<60 { state.record(entry(bytes: 10, at: TimeInterval(index))) }
        check(state.entries.count == 50, "capped at 50")
        check(state.entries.first?.date == start.addingTimeInterval(59), "newest first")
        check(state.entries.last?.date == start.addingTimeInterval(10), "oldest dropped")
        check(state.total(.github) == RequestTotal(count: 60, bytes: 600, failures: 0), "totals outlive the buffer")
        check(state.total(.slack).count == 0, "other services stay empty")
    }),
    ("request log totals separate services and count failures", {
        var state = RequestLogState()
        state.record(entry(.github, bytes: 2000, failed: true))
        state.record(entry(.slack, bytes: 500))
        check(state.total(.github).failures == 1, "a failed request")
        check(state.usedServices == [.github, .slack], "only used services, in order")
        check(RequestLogs.summary(state) == "GitHub 1 request, 2.0 KB, 1 failed; Slack 1 request, 500 B", "summary")
        state.clear()
        check(state.entries.isEmpty && state.usedServices.isEmpty, "clear empties everything")
    }),
    ("request log counts the bytes of the last hour", {
        var state = RequestLogState()
        state.record(entry(.github, bytes: 1000, at: 0))
        state.record(entry(.slack, bytes: 300, at: 3000))
        let now = start.addingTimeInterval(3700)
        check(state.bytesLastHour(now: now) == 300, "the first is older than an hour")
        check(state.bytesLastHour(now: now, service: .github) == 0, "per service")
        check(state.bytesLastHour(now: start.addingTimeInterval(3100)) == 1300, "both inside the hour")
        state.record(entry(.github, bytes: 1, at: 7300))
        check(state.samples.count == 1, "old samples are dropped")
    }),
    ("request log formats sizes and durations", {
        check(RequestLogs.size(0) == "0 B", "zero")
        check(RequestLogs.size(999) == "999 B", "bytes")
        check(RequestLogs.size(1500) == "1.5 KB", "one decimal under ten")
        check(RequestLogs.size(38_400) == "38 KB", "whole kilobytes")
        check(RequestLogs.size(2_300_000) == "2.3 MB", "megabytes")
        check(RequestLogs.duration(0.25) == "250 ms", "milliseconds")
        check(RequestLogs.duration(1.26) == "1.3 s", "seconds")
    }),
    ("request log labels name the endpoint and nothing else", {
        check(RequestLogs.ghLabel(["pr", "list", "--search", "secret words"]) == "gh pr list", "command only")
        check(RequestLogs.ghLabel(["api", "graphql", "-f", "query=x"]) == "gh api graphql", "graphql")
        check(RequestLogs.ghLabel(["api", "repos/o/r/pulls/1/files?page=2"]) == "gh api repos/o/r/pulls/1/files", "query dropped")
        check(RequestLogs.endpoint(URL(string: "https://slack.com/api/conversations.history?token=xoxp-1&channel=C1")) == "conversations.history", "slack method")
        check(RequestLogs.endpoint(URL(string: "https://acme.atlassian.net/rest/api/3/issue/ACME-1?fields=x")) == "/rest/api/3/issue/ACME-1", "jira path")
        check(RequestLogs.ghStatus(exit: 0, stderr: "") == ("ok", false), "success")
        check(RequestLogs.ghStatus(exit: 1, stderr: "gh: HTTP 502 Bad Gateway") == ("HTTP 502", true), "http status from the message")
        check(RequestLogs.ghStatus(exit: 4, stderr: "boom") == ("exit 4", true), "exit code")
        check(RequestLogs.httpStatus(200) == ("HTTP 200", false) && RequestLogs.httpStatus(429).failed && RequestLogs.httpStatus(0).failed, "http statuses")
    }),
    ("request log survives the file the MCP server reads", {
        var state = RequestLogState()
        state.record(entry(.github, bytes: 38_000, failed: true))
        let file = RequestLogs.File(written: start, state: state)
        check(RequestLogs.decode(RequestLogs.encode(file)) == file, "round trip")
        let text = RequestLogs.markdown(file, now: start, timeZone: TimeZone(identifier: "UTC")!)
        check(text.contains("GitHub 1 request, 38 KB, 1 failed") && text.contains("HTTP 502 FAILED"), "markdown: \(text)")
        check(RequestLogs.markdown(.init(written: start, state: RequestLogState()), now: start).hasPrefix("No external requests"), "empty")
    }),
]
