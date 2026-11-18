import SwiftUI

/// Settings → Usage → Network requests: the last calls WorkTime made to GitHub, Slack, Jira and the rest, with their size.
struct RequestLogSection: View {
    @ObservedObject var log: RequestLog

    var body: some View {
        let state = log.state
        SettingsSection("Network requests", footer: "The last \(RequestLogState.capacity) calls since WorkTime started: only the endpoint, the status and the size are kept, never a body or a token.") {
            if state.entries.isEmpty {
                SettingsRow("Nothing yet", detail: "Requests to GitHub, Slack, Jira and Claude show up here as they are made.") {}
            } else {
                SettingsRow("Since launch", detail: "\(RequestLogs.size(state.bytesLastHour(now: Date()))) in the last hour") {
                    Button("Clear") { log.clear() }
                }
                ForEach(state.usedServices, id: \.self) { service in
                    let total = state.total(service)
                    Divider().padding(.leading, 14)
                    SettingsRow(service.rawValue, detail: total.failures > 0 ? "\(total.failures) failed" : nil) {
                        Text("\(total.count) request\(total.count == 1 ? "" : "s"), \(RequestLogs.size(total.bytes))").monospacedDigit()
                    }
                }
                Divider().padding(.leading, 14)
                ForEach(state.entries) { entry in
                    row(entry)
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    private func row(_ entry: RequestEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.date, style: .time).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(entry.service.rawValue).frame(width: 64, alignment: .leading)
            Text(entry.what).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(RequestLogs.size(entry.bytes)).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(entry.status).foregroundStyle(entry.failed ? .red : .secondary).frame(width: 70, alignment: .leading)
            Text(RequestLogs.duration(entry.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(entry.failed ? Color.red.opacity(0.12) : .clear)
    }
}
