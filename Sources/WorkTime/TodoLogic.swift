import Foundation

struct MeetingTodo: Identifiable, Equatable {
    var id: Int64
    var meeting: Int64
    var date: Date
    var title: String
    var owner: String?
    var task: String
}

enum TodoLogic {
    static let meetingDays = 14
    static let todoLimit = 50
    static let meetingLimit = 50

    static func text(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func meetingCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(meetingDays) * 24 * 3600)
    }
}
