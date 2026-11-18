import Foundation

enum RequestService: String, Codable, CaseIterable {
    case github = "GitHub"
    case slack = "Slack"
    case jira = "Jira"
    case anthropic = "Anthropic"
    case other = "Other"
}

struct RequestEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var service: RequestService
    var what: String
    var status: String
    var failed: Bool
    var bytes: Int
    var duration: TimeInterval
}

struct RequestTotal: Codable, Equatable {
    var count = 0
    var bytes = 0
    var failures = 0
}

/// The last requests, newest first, and what each service has cost since launch. Only the endpoint and the size are kept, never a body.
struct RequestLogState: Codable, Equatable {
    struct Sample: Codable, Equatable {
        var date: Date
        var service: RequestService
        var bytes: Int
    }

    static let capacity = 50
    static let window: TimeInterval = 3600

    var entries: [RequestEntry] = []
    var totals: [String: RequestTotal] = [:]
    var samples: [Sample] = []

    mutating func record(_ entry: RequestEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        var total = totals[entry.service.rawValue] ?? RequestTotal()
        total.count += 1
        total.bytes += entry.bytes
        if entry.failed { total.failures += 1 }
        totals[entry.service.rawValue] = total
        samples.append(Sample(date: entry.date, service: entry.service, bytes: entry.bytes))
        samples.removeAll { entry.date.timeIntervalSince($0.date) > Self.window }
    }

    mutating func clear() { self = RequestLogState() }

    func total(_ service: RequestService) -> RequestTotal { totals[service.rawValue] ?? RequestTotal() }

    func bytesLastHour(now: Date, service: RequestService? = nil) -> Int {
        samples.filter { now.timeIntervalSince($0.date) <= Self.window && (service == nil || $0.service == service) }.reduce(0) { $0 + $1.bytes }
    }

    var usedServices: [RequestService] { RequestService.allCases.filter { total($0).count > 0 } }
}

enum RequestLogs {
    static let fileName = "requests.json"

    struct File: Codable, Equatable {
        var written: Date
        var state: RequestLogState
    }

    static func size(_ bytes: Int) -> String {
        switch bytes {
        case ..<1000: return "\(bytes) B"
        case ..<1_000_000: return scaled(Double(bytes) / 1000, unit: "KB")
        default: return scaled(Double(bytes) / 1_000_000, unit: "MB")
        }
    }

    private static func scaled(_ value: Double, unit: String) -> String {
        value >= 10 ? "\(Int(value.rounded())) \(unit)" : String(format: "%.1f %@", value, unit)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    /// `gh pr list`, `gh api graphql`, `gh api repos/o/r/pulls/1/files`: the command and its endpoint, never a flag value.
    static func ghLabel(_ arguments: [String]) -> String {
        let words = arguments.prefix(2).filter { !$0.hasPrefix("-") }.map { $0.split(separator: "?").first.map(String.init) ?? $0 }
        return (["gh"] + words).joined(separator: " ")
    }

    /// The exit code of a `gh` call, or the HTTP status its message names (`gh: HTTP 502`).
    static func ghStatus(exit: Int32, stderr: String) -> (text: String, failed: Bool) {
        guard exit != 0 else { return ("ok", false) }
        if let range = stderr.range(of: #"HTTP [0-9]{3}"#, options: .regularExpression) { return (String(stderr[range]), true) }
        return ("exit \(exit)", true)
    }

    /// `conversations.history` for `https://slack.com/api/conversations.history?token=...`, the path for the rest; the query is dropped.
    static func endpoint(_ url: URL?) -> String {
        guard let path = url?.path, !path.isEmpty else { return "request" }
        return path.hasPrefix("/api/") ? String(path.dropFirst(5)) : path
    }

    static func httpStatus(_ code: Int) -> (text: String, failed: Bool) {
        (code == 0 ? "no response" : "HTTP \(code)", !(200..<300).contains(code))
    }

    static func encode(_ file: File) -> Data { AgentInbox.encode(file) }

    static func decode(_ data: Data?) -> File? { data.flatMap { AgentInbox.decode(File.self, from: $0) } }

    static func summary(_ state: RequestLogState) -> String {
        state.usedServices.map { service in
            let total = state.total(service)
            return "\(service.rawValue) \(total.count) request\(total.count == 1 ? "" : "s"), \(size(total.bytes))" + (total.failures > 0 ? ", \(total.failures) failed" : "")
        }.joined(separator: "; ")
    }

    static func markdown(_ file: File, now: Date, timeZone: TimeZone = .current) -> String {
        let state = file.state
        guard !state.entries.isEmpty else { return "No external requests since WorkTime started (or since the log was cleared)." }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm:ss"
        var lines = ["Since launch: " + summary(state), "Last hour: \(size(state.bytesLastHour(now: now)))", "", "Last \(state.entries.count) requests, newest first:"]
        lines += state.entries.map {
            "\(clock.string(from: $0.date)) \($0.service.rawValue) \($0.what) \(size($0.bytes)) \($0.status)\($0.failed ? " FAILED" : "") \(duration($0.duration))"
        }
        return lines.joined(separator: "\n")
    }
}
