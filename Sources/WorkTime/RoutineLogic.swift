import Foundation

/// When a routine runs: every so many minutes, or at a time of day on every day, on weekdays, or on one weekday.
struct RoutineSchedule: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case interval, daily, weekdays, weekly

        var id: String { rawValue }
        var title: String {
            switch self {
            case .interval: "Every"
            case .daily: "Every day"
            case .weekdays: "Weekdays"
            case .weekly: "Every week"
            }
        }
    }

    static let shortestInterval = 5

    var kind: Kind
    /// For `interval`.
    var minutes = 60
    var hour = 9
    var minute = 0
    /// For `weekly`, as `Calendar` counts: 1 is Sunday.
    var weekday = 2

    static func every(minutes: Int) -> RoutineSchedule { RoutineSchedule(kind: .interval, minutes: minutes) }

    /// The first time after `date` the routine is due.
    func next(after date: Date, calendar: Calendar = .current) -> Date {
        func time(weekday: Int? = nil, after start: Date) -> Date {
            let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
            return calendar.nextDate(after: start, matching: components, matchingPolicy: .nextTime) ?? start.addingTimeInterval(86_400)
        }
        switch kind {
        case .interval: return date.addingTimeInterval(TimeInterval(max(minutes, Self.shortestInterval)) * 60)
        case .daily: return time(after: date)
        case .weekly: return time(weekday: weekday, after: date)
        case .weekdays:
            var due = time(after: date)
            while [1, 7].contains(calendar.component(.weekday, from: due)) { due = time(after: due) }
            return due
        }
    }

    func label(calendar: Calendar = .current) -> String {
        let clock = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .interval: return minutes % 60 == 0 && minutes >= 60 ? "Every \(minutes / 60 == 1 ? "hour" : "\(minutes / 60) hours")" : "Every \(minutes) minutes"
        case .daily: return "Every day at \(clock)"
        case .weekdays: return "Weekdays at \(clock)"
        case .weekly: return "Every \(calendar.weekdaySymbols[(weekday - 1) % 7]) at \(clock)"
        }
    }
}

/// One run of a routine: its session stays in the routine's history, this is what the sidebar and the notification say.
struct RoutineRun: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case running, done, failed, interrupted }

    var started: Date
    var finished: Date?
    var status: Status
    var summary: String?
    /// How many calls that needed approval were refused, as nobody is there to give it.
    var denied = 0
}

/// A saved prompt that runs on a schedule in an agent of its own, a fresh session each time, optionally as one of a
/// workspace's assistants (its instructions, tools and permissions).
struct Routine: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var prompt: String
    var workspace: String
    var assistant: String?
    var folder: String?
    var model: String?
    var schedule: RoutineSchedule
    var enabled = true
    var runMissed = false
    var created: Date
    var nextRun: Date?
    var lastRun: RoutineRun?
    /// An automation: started by an event instead of the schedule, which is then unused.
    var trigger: AutomationTrigger?
    var followUp: AutomationFollowUp?

    var key: String { Routines.prefix + id }
    var isAutomation: Bool { trigger != nil }
}

enum Routines {
    static let prefix = "routine:"
    static let nameLimit = 60
    static let collapsedKey = "agentRoutinesCollapsed"
    static let automationsCollapsedKey = "agentAutomationsCollapsed"
    /// A run this much later than it was due counts as missed: the app was closed or the Mac asleep.
    static let missedGrace: TimeInterval = 120
    static let notificationLines = 3
    static let notificationLimit = 300

    static func isKey(_ key: String) -> Bool {
        key.hasPrefix(prefix) && UUID(uuidString: String(key.dropFirst(prefix.count))) != nil
    }

    /// Why the routine cannot be saved, nil when it can.
    static func problem(name: String, prompt: String, schedule: RoutineSchedule, trigger: AutomationTrigger? = nil) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the routine a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write what the routine should do." }
        if let trigger { return Automations.problem(trigger) }
        if schedule.kind == .interval, schedule.minutes < RoutineSchedule.shortestInterval {
            return "A routine runs at most every \(RoutineSchedule.shortestInterval) minutes."
        }
        return nil
    }

    /// The routine as saved: trimmed, and due next at its schedule's next time when it is on.
    static func armed(_ routine: Routine, now: Date, calendar: Calendar = .current) -> Routine {
        var routine = routine
        routine.name = String(routine.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit))
        routine.prompt = routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.nextRun = routine.enabled && routine.trigger == nil ? routine.schedule.next(after: now, calendar: calendar) : nil
        return routine
    }

    /// Which routines to start now and the routines with their next time moved on. A routine still running is skipped, never
    /// started twice, and one that is far past due (the app was closed or asleep) starts only when it asks for missed runs.
    static func tick(_ routines: [Routine], now: Date, running: Set<String>, calendar: Calendar = .current) -> (routines: [Routine], fire: [String]) {
        var fire: [String] = []
        let updated = routines.map { routine -> Routine in
            var routine = routine
            guard routine.enabled, routine.trigger == nil else { return routine }
            guard let due = routine.nextRun else {
                routine.nextRun = routine.schedule.next(after: now, calendar: calendar)
                return routine
            }
            guard due <= now else { return routine }
            routine.nextRun = routine.schedule.next(after: now, calendar: calendar)
            guard !running.contains(routine.id) else { return routine }
            if now.timeIntervalSince(due) > missedGrace && !routine.runMissed { return routine }
            fire.append(routine.id)
            return routine
        }
        return (updated, fire)
    }

    /// Routines left running when the app quit did not finish.
    static func settled(_ routines: [Routine], now: Date) -> [Routine] {
        routines.map { routine in
            guard routine.lastRun?.status == .running else { return routine }
            var routine = routine
            routine.lastRun?.status = .interrupted
            routine.lastRun?.finished = now
            return routine
        }
    }

    static func started(_ routine: Routine, now: Date) -> Routine {
        var routine = routine
        routine.lastRun = RoutineRun(started: now, status: .running)
        return routine
    }

    /// How a finished run went, from its transcript: the last reply, or the error that stopped it.
    static func outcome(items: [AgentItem], started: Date, now: Date) -> RoutineRun {
        let denied = items.filter { if case .permission(_, _, _, _, false) = $0.kind { true } else { false } }.count
        func failure(_ item: AgentItem) -> String? {
            switch item.kind {
            case .error(let text): text
            case .missingFolder(let folder): AgentFolders.missingMessage(folder)
            default: nil
            }
        }
        func reply(_ item: AgentItem) -> String? {
            if case .text(let text) = item.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            return nil
        }
        var run = RoutineRun(started: started, finished: now, status: .done, denied: denied)
        let lastReply = items.lastIndex { reply($0) != nil }, lastFailure = items.lastIndex { failure($0) != nil }
        if let lastFailure, lastFailure > (lastReply ?? -1) {
            run.status = .failed
            run.summary = failure(items[lastFailure])
        } else {
            run.summary = lastReply.flatMap { reply(items[$0]) }
        }
        return run
    }

    /// What the notification of a finished run says: the first lines of the answer, and what was refused.
    static func notification(for routine: Routine, run: RoutineRun) -> (title: String, body: String) {
        let answer = (run.summary ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var body = answer.prefix(notificationLines).joined(separator: "\n")
        if body.count > notificationLimit { body = String(body.prefix(notificationLimit - 1)) + "\u{2026}" }
        if body.isEmpty { body = run.status == .failed ? "The run failed." : "Finished without a reply." }
        if run.status == .failed { body = "Failed: " + body }
        if run.denied > 0 { body += "\n\(run.denied) call\(run.denied == 1 ? " was" : "s were") refused: nobody was there to approve."}
        return (routine.name, body)
    }

    /// The row's second line: the schedule, and what is next or how the last run went.
    static func detail(_ routine: Routine, now: Date) -> String {
        let when = routine.trigger.map(Automations.label) ?? routine.schedule.label()
        guard routine.enabled else { return "\(when) \u{00B7} off" }
        return "\(when) \u{00B7} \(lastRunText(routine.lastRun, now: now))"
    }

    static func lastRunText(_ run: RoutineRun?, now: Date) -> String {
        guard let run else { return "not run yet" }
        let when = GitHubLogic.updatedText(run.finished ?? run.started, now: now)
        switch run.status {
        case .running: return "running"
        case .done: return run.denied > 0 ? "ran \(when), \(run.denied) refused" : "ran \(when)"
        case .failed: return "failed \(when)"
        case .interrupted: return "stopped \(when)"
        }
    }

    /// Added to the routine's agent: nobody is watching a scheduled run.
    static func systemPrompt(_ routine: Routine, base: String?) -> String {
        let note = "This is the \(routine.isAutomation ? "automation" : "scheduled routine") \u{201C}\(routine.name)\u{201D}, running on its own with nobody at the keyboard. "
            + "Do not ask questions or wait for an answer. A call that needs approval is refused, so work with what you are allowed to do and say what you "
            + "could not. Finish with a short summary of the result: its first lines are shown in a notification."
        return [base, note, routine.isAutomation ? Automations.systemNote(routine) : nil].compactMap { $0 }.joined(separator: "\n\n")
    }

    static func encode(_ routines: [Routine]) -> Data { AgentInbox.encode(routines) }

    static func decode(_ data: Data?) -> [Routine] {
        data.flatMap { AgentInbox.decode([Routine].self, from: $0) } ?? []
    }
}
