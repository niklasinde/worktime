import Foundation

/// Time logged on a ticket: Jira's own notation for a duration (`1h 30m`, `2d`, `1w 2d`) and the request that logs it.
enum JiraWorklog {
    static let hoursPerDay = 8
    static let daysPerWeek = 5
    static let longest = 24 * 7 * 3600

    static func path(_ key: String) -> String { "/rest/api/3/issue/\(key)/worklog" }

    /// The seconds a typed duration stands for, at Jira's eight-hour day and five-day week; nil for anything else or under a minute.
    static func seconds(_ text: String) -> Int? {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let clock = text.wholeMatch(of: #/(\d{1,3}):([0-5]\d)/#), let hours = Int(clock.1), let minutes = Int(clock.2) {
            return valid(hours * 3600 + minutes * 60)
        }
        var rest = Substring(text)
        var total = 0.0
        var found = false
        while let part = rest.prefixMatch(of: #/\s*(\d+(?:[.,]\d+)?)\s*([wdhm])[a-z]*\s*(?:,|and)?/#) {
            guard let amount = Double(part.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total += amount * unit(part.2)
            found = true
            rest = rest[part.range.upperBound...]
        }
        guard found, rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return valid(Int(total.rounded()))
    }

    private static func unit(_ letter: Substring) -> Double {
        let hour = 3600.0
        switch letter {
        case "w": return hour * Double(hoursPerDay * daysPerWeek)
        case "d": return hour * Double(hoursPerDay)
        case "h": return hour
        default: return 60
        }
    }

    private static func valid(_ seconds: Int) -> Int? { seconds >= 60 && seconds <= longest ? seconds : nil }

    /// `2d 3h 30m`: days of eight hours, as Jira counts them.
    static func format(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let perDay = hoursPerDay * 60
        let parts = [("d", minutes / perDay), ("h", minutes % perDay / 60), ("m", minutes % 60)].filter { $0.1 > 0 }
        return parts.isEmpty ? "0m" : parts.map { "\($0.1)\($0.0)" }.joined(separator: " ")
    }

    /// The time Jira wants for when the work started: `2026-11-16T09:30:00.000+0100`.
    static func started(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.string(from: date)
    }

    static func body(seconds: Int, started: Date, comment: String, timeZone: TimeZone = .current) -> [String: Any] {
        var body: [String: Any] = ["timeSpentSeconds": seconds, "started": Self.started(started, timeZone: timeZone)]
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body["comment"] = JiraWrite.document(String(text.prefix(JiraWrite.commentLimit))) }
        return body
    }
}
