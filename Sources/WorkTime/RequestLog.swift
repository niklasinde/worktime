import Combine
import Foundation

/// Every call WorkTime makes to the outside, newest first, for Settings and the `request_log` MCP tool. Safe to call from any thread.
final class RequestLog: ObservableObject, @unchecked Sendable {
    static let shared = RequestLog()

    @Published private(set) var state = RequestLogState()

    private let lock = NSLock()
    private var current = RequestLogState()
    private var publishing = false
    private let file: URL

    init(file: URL = AppPaths.requestLog) { self.file = file }

    func record(service: RequestService, what: String, bytes: Int, duration: TimeInterval, status: String, failed: Bool, date: Date = Date()) {
        lock.lock()
        current.record(RequestEntry(date: date, service: service, what: what, status: status, failed: failed, bytes: bytes, duration: duration))
        let schedule = !publishing
        publishing = true
        lock.unlock()
        if schedule { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.publish() } }
    }

    func record(service: RequestService, what: String, bytes: Int, started: Date, status: (text: String, failed: Bool)) {
        record(service: service, what: what, bytes: bytes, duration: Date().timeIntervalSince(started), status: status.text, failed: status.failed)
    }

    func clear() {
        lock.lock()
        current.clear()
        lock.unlock()
        publish()
    }

    /// `URLSession.data(for:)` with the request recorded under `service`.
    func data(for request: URLRequest, service: RequestService) async throws -> (Data, HTTPURLResponse?) {
        let started = Date()
        let what = RequestLogs.endpoint(request.url)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            record(service: service, what: what, bytes: data.count, started: started, status: RequestLogs.httpStatus(http?.statusCode ?? 0))
            return (data, http)
        } catch {
            record(service: service, what: what, bytes: 0, started: started, status: (error.localizedDescription, true))
            throw error
        }
    }

    private func publish() {
        lock.lock()
        let snapshot = current
        publishing = false
        lock.unlock()
        state = snapshot
        let url = file
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? RequestLogs.encode(.init(written: Date(), state: snapshot)).write(to: url, options: .atomic)
        }
    }
}
