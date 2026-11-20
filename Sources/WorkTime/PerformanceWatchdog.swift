import Foundation

struct PerformanceWatchdogPolicy: Equatable {
    let stallThreshold: TimeInterval
    let cooldown: TimeInterval
    let maxFiles: Int
    private(set) var lastHeartbeat: TimeInterval
    private(set) var lastCapture: TimeInterval?
    private(set) var captureRunning = false

    init(stallThreshold: TimeInterval = 3, cooldown: TimeInterval = 300, maxFiles: Int = 5, now: TimeInterval = 0) {
        self.stallThreshold = stallThreshold
        self.cooldown = cooldown
        self.maxFiles = maxFiles
        lastHeartbeat = now
    }

    mutating func heartbeat(at time: TimeInterval) {
        lastHeartbeat = max(lastHeartbeat, time)
    }

    mutating func shouldCapture(at time: TimeInterval) -> Bool {
        guard !captureRunning, time - lastHeartbeat >= stallThreshold,
              lastCapture.map({ time - $0 >= cooldown }) ?? true else { return false }
        captureRunning = true
        lastCapture = time
        return true
    }

    mutating func captureFinished() {
        captureRunning = false
    }

    func filesToRemove(_ names: [String]) -> [String] {
        guard maxFiles >= 0 else { return names }
        return Array(names.sorted(by: >).dropFirst(maxFiles))
    }
}

final class PerformanceWatchdog: @unchecked Sendable {
    static let shared = PerformanceWatchdog()

    private let queue = DispatchQueue(label: "com.niklasinde.WorkTime.performance-watchdog", qos: .utility)
    private let directory: URL
    private var policy: PerformanceWatchdogPolicy
    private var timer: DispatchSourceTimer?
    private var sampleProcess: Process?

    init(directory: URL = AppPaths.diagnostics, policy: PerformanceWatchdogPolicy = PerformanceWatchdogPolicy()) {
        self.directory = directory
        self.policy = policy
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            policy.heartbeat(at: ProcessInfo.processInfo.systemUptime)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            sampleProcess?.terminate()
            sampleProcess = nil
            policy.captureFinished()
        }
    }

    private func tick() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queue.async { [self] in self.policy.heartbeat(at: ProcessInfo.processInfo.systemUptime) }
        }
        guard policy.shouldCapture(at: ProcessInfo.processInfo.systemUptime) else { return }
        capture()
    }

    private func capture() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            let output = directory.appendingPathComponent("hang-\(timestamp())-pid\(pid).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "3", "-file", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] finished in
                guard let self else { return }
                queue.async { [self] in
                    if finished.terminationStatus != 0 { try? FileManager.default.removeItem(at: output) }
                    self.rotate()
                    self.sampleProcess = nil
                    self.policy.captureFinished()
                }
            }
            sampleProcess = process
            try process.run()
        } catch {
            sampleProcess = nil
            policy.captureFinished()
        }
    }

    private func rotate() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let reports = files.filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "txt" }
        let remove = Set(policy.filesToRemove(reports.map(\.lastPathComponent)))
        for file in reports where remove.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
