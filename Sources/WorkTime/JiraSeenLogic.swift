import Foundation

/// When the user last looked at each ticket, so the list can mark the ones that changed since.
struct JiraSeen: Codable, Equatable {
    static let key = "jiraSeen"
    /// A ticket the user changed or opened is updated a moment after the clock says they looked; that is not a change.
    static let grace: TimeInterval = 30
    static let kept: TimeInterval = 90 * 86_400

    /// Nothing before this counts as a change: when the page first ran, or when everything was last marked seen.
    var baseline: Date
    var seen: [String: Date] = [:]

    func isUnseen(_ ticket: JiraTicket) -> Bool {
        guard let updated = ticket.updated else { return false }
        return updated > max(seen[ticket.key] ?? baseline, baseline).addingTimeInterval(Self.grace)
    }

    func unseen(_ tickets: [JiraTicket]) -> [JiraTicket] { tickets.filter(isUnseen) }

    func marked(_ key: String, now: Date) -> JiraSeen {
        var next = self
        next.seen[key] = now
        return next
    }

    func markedAll(now: Date) -> JiraSeen { JiraSeen(baseline: now) }

    func pruned(now: Date) -> JiraSeen {
        var next = self
        next.seen = seen.filter { now.timeIntervalSince($0.value) < Self.kept && $0.value > baseline }
        return next
    }

    static func decode(_ data: Data?, now: Date) -> JiraSeen {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.flatMap { try? decoder.decode(JiraSeen.self, from: $0) }?.pruned(now: now) ?? JiraSeen(baseline: now)
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
