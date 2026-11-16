import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

/// 16 November 2026 is a Monday.
private let monday10 = date(16, 10, 0)

private func routine(_ schedule: RoutineSchedule, enabled: Bool = true, runMissed: Bool = false, nextRun: Date? = nil, id: String = UUID().uuidString) -> Routine {
    Routine(id: id, name: "Morning sweep", prompt: "Check my pull requests", workspace: "work", schedule: schedule, enabled: enabled,
            runMissed: runMissed, created: monday10, nextRun: nextRun)
}

private func item(_ kind: AgentItem.Kind) -> AgentItem { AgentItem(id: UUID().uuidString, kind: kind) }

let routineTests: [(name: String, run: () throws -> Void)] = [
    ("routines: an interval is due that long after the last time, never sooner than the shortest", {
        check(RoutineSchedule.every(minutes: 90).next(after: monday10, calendar: calendar) == date(16, 11, 30), "90 minutes")
        check(RoutineSchedule.every(minutes: 1).next(after: monday10, calendar: calendar) == date(16, 10, 5), "clamped to 5 minutes")
    }),

    ("routines: a daily time is today when it is still ahead and tomorrow when it has passed", {
        let nine = RoutineSchedule(kind: .daily, hour: 9, minute: 30)
        check(nine.next(after: date(16, 8, 0), calendar: calendar) == date(16, 9, 30), "ahead")
        check(nine.next(after: monday10, calendar: calendar) == date(17, 9, 30), "passed")
        check(nine.next(after: date(16, 9, 30), calendar: calendar) == date(17, 9, 30), "exactly now is already done")
    }),

    ("routines: weekdays skip the weekend and weekly keeps its day", {
        let weekdays = RoutineSchedule(kind: .weekdays, hour: 8, minute: 0)
        check(weekdays.next(after: date(20, 9, 0), calendar: calendar) == date(23, 8, 0), "Friday evening goes to Monday")
        check(weekdays.next(after: date(21, 12, 0), calendar: calendar) == date(23, 8, 0), "Saturday goes to Monday")
        check(weekdays.next(after: date(16, 7, 0), calendar: calendar) == date(16, 8, 0), "Monday morning is today")
        let friday = RoutineSchedule(kind: .weekly, hour: 16, minute: 0, weekday: 6)
        check(friday.next(after: monday10, calendar: calendar) == date(20, 16, 0), "next Friday")
        check(friday.next(after: date(20, 16, 0), calendar: calendar) == date(27, 16, 0), "a week on")
    }),

    ("routines: schedules are described", {
        check(RoutineSchedule.every(minutes: 30).label(calendar: calendar) == "Every 30 minutes", "minutes")
        check(RoutineSchedule.every(minutes: 60).label(calendar: calendar) == "Every hour", "hour")
        check(RoutineSchedule.every(minutes: 120).label(calendar: calendar) == "Every 2 hours", "hours")
        check(RoutineSchedule(kind: .weekdays, hour: 8, minute: 5).label(calendar: calendar) == "Weekdays at 08:05", "weekdays")
        check(RoutineSchedule(kind: .weekly, hour: 16, minute: 0, weekday: 6).label(calendar: calendar) == "Every Friday at 16:00", "weekly")
    }),

    ("routines: saving needs a name, a prompt and a sane interval, and arms the next run", {
        let schedule = RoutineSchedule(kind: .daily)
        check(Routines.problem(name: " ", prompt: "x", schedule: schedule) != nil, "no name")
        check(Routines.problem(name: "x", prompt: "\n", schedule: schedule) != nil, "no prompt")
        check(Routines.problem(name: "x", prompt: "x", schedule: .every(minutes: 2)) != nil, "too often")
        check(Routines.problem(name: "x", prompt: "x", schedule: schedule) == nil, "fine")
        let armed = Routines.armed(routine(RoutineSchedule(kind: .daily, hour: 9, minute: 0)), now: monday10, calendar: calendar)
        check(armed.nextRun == date(17, 9, 0), "\(String(describing: armed.nextRun))")
        check(Routines.armed(routine(schedule, enabled: false, nextRun: monday10), now: monday10, calendar: calendar).nextRun == nil, "off has no next run")
    }),

    ("routines: a due routine starts once and its next time moves on", {
        let due = routine(.every(minutes: 60), nextRun: date(16, 9, 59))
        let result = Routines.tick([due], now: monday10, running: [], calendar: calendar)
        check(result.fire == [due.id], "\(result.fire)")
        check(result.routines[0].nextRun == date(16, 11, 0), "\(String(describing: result.routines[0].nextRun))")
        let early = Routines.tick([routine(.every(minutes: 60), nextRun: date(16, 10, 30))], now: monday10, running: [], calendar: calendar)
        check(early.fire.isEmpty && early.routines[0].nextRun == date(16, 10, 30), "not due yet")
    }),

    ("routines: a routine that is still running is not started again, and its next time still moves on", {
        let due = routine(.every(minutes: 60), nextRun: date(16, 9, 59))
        let result = Routines.tick([due], now: monday10, running: [due.id], calendar: calendar)
        check(result.fire.isEmpty, "overlap")
        check(result.routines[0].nextRun == date(16, 11, 0), "no catching up afterwards")
    }),

    ("routines: a run missed while the app was closed starts only for a routine that asks for it", {
        let long = date(16, 6, 0)
        let skipped = Routines.tick([routine(.every(minutes: 60), nextRun: long)], now: monday10, running: [], calendar: calendar)
        check(skipped.fire.isEmpty && skipped.routines[0].nextRun == date(16, 11, 0), "left alone")
        let asked = routine(.every(minutes: 60), runMissed: true, nextRun: long)
        check(Routines.tick([asked], now: monday10, running: [], calendar: calendar).fire == [asked.id], "missed run fires once")
        let slightlyLate = routine(.every(minutes: 60), nextRun: monday10.addingTimeInterval(-Routines.missedGrace + 5))
        check(Routines.tick([slightlyLate], now: monday10, running: [], calendar: calendar).fire == [slightlyLate.id], "a timer that fired late is not a missed run")
    }),

    ("routines: switched-off routines never fire, and one without a next time gets one", {
        let off = routine(.every(minutes: 60), enabled: false, nextRun: date(16, 9, 0))
        check(Routines.tick([off], now: monday10, running: [], calendar: calendar).fire.isEmpty, "off")
        let fresh = Routines.tick([routine(.every(minutes: 60))], now: monday10, running: [], calendar: calendar)
        check(fresh.fire.isEmpty && fresh.routines[0].nextRun == date(16, 11, 0), "armed")
    }),

    ("routines: a run left running by a quit is marked stopped", {
        var running = routine(.every(minutes: 60))
        running.lastRun = RoutineRun(started: date(16, 9, 0), status: .running)
        var done = routine(.every(minutes: 60))
        done.lastRun = RoutineRun(started: date(16, 9, 0), finished: date(16, 9, 1), status: .done)
        let settled = Routines.settled([running, done], now: monday10)
        check(settled[0].lastRun?.status == .interrupted && settled[0].lastRun?.finished == monday10, "interrupted")
        check(settled[1] == done, "finished runs stay")
    }),

    ("routines: a run's outcome is its last reply, the error that stopped it, and the calls that were refused", {
        let ok = Routines.outcome(items: [item(.user("go")), item(.text("Looking")), item(.tool(name: "Bash", summary: "ls", detail: "", result: nil, isError: false, auto: true)),
                                          item(.text("Two PRs need you.\nBoth are small."))], started: monday10, now: date(16, 10, 2))
        check(ok.status == .done && ok.summary == "Two PRs need you.\nBoth are small." && ok.denied == 0, "\(ok)")
        let failed = Routines.outcome(items: [item(.user("go")), item(.error("The agent stopped (exit 1)."))], started: monday10, now: date(16, 10, 2))
        check(failed.status == .failed && failed.summary == "The agent stopped (exit 1).", "\(failed)")
        let late = Routines.outcome(items: [item(.text("Half done")), item(.error("The agent stopped (exit 1)."))], started: monday10, now: date(16, 10, 2))
        check(late.status == .failed, "an error after the last reply fails the run")
        let denied = Routines.outcome(items: [item(.permission(tool: "Bash", summary: "rm", detail: "", allowed: false)),
                                              item(.permission(tool: "Edit", summary: "x", detail: "", allowed: true)), item(.text("Done"))],
                                      started: monday10, now: date(16, 10, 2))
        check(denied.denied == 1 && denied.status == .done, "\(denied)")
        check(Routines.outcome(items: [item(.missingFolder("/gone"))], started: monday10, now: monday10).status == .failed, "missing folder")
    }),

    ("routines: the notification carries the first lines of the answer and what was refused", {
        let routine = routine(.every(minutes: 60))
        let run = RoutineRun(started: monday10, finished: monday10, status: .done, summary: "One\n\nTwo\nThree\nFour", denied: 2)
        let notice = Routines.notification(for: routine, run: run)
        check(notice.title == "Morning sweep", notice.title)
        check(notice.body == "One\nTwo\nThree\n2 calls were refused: nobody was there to approve.", notice.body)
        let failed = Routines.notification(for: routine, run: RoutineRun(started: monday10, finished: monday10, status: .failed, summary: "Boom"))
        check(failed.body == "Failed: Boom", failed.body)
        check(Routines.notification(for: routine, run: RoutineRun(started: monday10, finished: monday10, status: .done)).body == "Finished without a reply.", "no reply")
        let long = Routines.notification(for: routine, run: RoutineRun(started: monday10, finished: monday10, status: .done, summary: String(repeating: "x", count: 900)))
        check(long.body.count == Routines.notificationLimit, "\(long.body.count)")
    }),

    ("routines: the row says how the last run went", {
        var routine = routine(.every(minutes: 60))
        check(Routines.detail(routine, now: monday10) == "Every hour \u{00B7} not run yet", Routines.detail(routine, now: monday10))
        routine.lastRun = RoutineRun(started: monday10, status: .running)
        check(Routines.detail(routine, now: monday10).hasSuffix("running"), "running")
        routine.lastRun = RoutineRun(started: monday10, finished: monday10, status: .failed)
        check(Routines.detail(routine, now: monday10.addingTimeInterval(7200)).contains("failed"), "failed")
        routine.enabled = false
        check(Routines.detail(routine, now: monday10) == "Every hour \u{00B7} off", "off")
    }),

    ("routines: keys are the prefix and an id, the prompt says nobody is there, and the file round trips", {
        let made = routine(.every(minutes: 30))
        check(Routines.isKey(made.key) && !Routines.isKey("routine:nope") && !Routines.isKey("topic:" + made.id), "keys")
        check(Routines.systemPrompt(made, base: "Base").hasPrefix("Base\n\n") && Routines.systemPrompt(made, base: nil).contains("nobody at the keyboard"), "prompt")
        var saved = made
        saved.lastRun = RoutineRun(started: monday10, finished: date(16, 10, 1), status: .done, summary: "ok", denied: 1)
        saved.assistant = "assistant:work:developer"
        check(Routines.decode(Routines.encode([saved])) == [saved], "round trip")
        check(Routines.decode(Data("not json".utf8)).isEmpty && Routines.decode(nil).isEmpty, "unreadable file")
    }),
]
