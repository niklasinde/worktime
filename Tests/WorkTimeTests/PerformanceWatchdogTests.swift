import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let performanceWatchdogTests: [(name: String, run: () throws -> Void)] = [
    ("performance watchdog captures a sustained stall once", {
        var policy = PerformanceWatchdogPolicy(stallThreshold: 3, cooldown: 300, now: 10)
        check(!policy.shouldCapture(at: 12.9), "not stalled yet")
        check(policy.shouldCapture(at: 13), "stalled")
        check(!policy.shouldCapture(at: 20), "one capture at a time")
        policy.captureFinished()
        check(!policy.shouldCapture(at: 312.9), "cooldown")
        check(policy.shouldCapture(at: 313), "captures again after cooldown")
    }),
    ("performance watchdog heartbeat clears a pending stall", {
        var policy = PerformanceWatchdogPolicy(stallThreshold: 3, cooldown: 300, now: 10)
        policy.heartbeat(at: 12)
        check(!policy.shouldCapture(at: 14.9), "recent heartbeat")
        check(policy.shouldCapture(at: 15), "heartbeat then stalled")
    }),
    ("performance watchdog keeps only the newest reports", {
        let policy = PerformanceWatchdogPolicy(maxFiles: 3)
        let names = ["hang-20261120-090000-pid1.txt", "hang-20261120-090400-pid1.txt",
                     "hang-20261120-090200-pid1.txt", "hang-20261120-090300-pid1.txt"]
        check(policy.filesToRemove(names) == ["hang-20261120-090000-pid1.txt"], "oldest removed")
    }),
]
