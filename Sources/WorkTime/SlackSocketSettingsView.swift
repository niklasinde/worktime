import AppKit
import SwiftUI

/// Settings › Slack: the app-level token for Socket Mode, so Slack automations fire as the message is written, with the steps and the
/// manifest to set it up.
struct SlackSocketSettingsSection: View {
    @ObservedObject var socket: SlackSocket
    @State private var token = ""
    @State private var result: (text: String, failed: Bool)?
    @State private var testing = false
    @State private var setup = false
    @State private var copied = false

    var body: some View {
        SettingsSection("Slack live events", footer: "With an app-level token, Slack automations fire within seconds of a message instead of up to five "
                        + "minutes later. WorkTime only connects while a Slack automation is on, reads messages you can already see, and never posts. "
                        + "The search every five minutes stays as a safety net. The token is kept in the app's private secrets file and only sent to Slack.") {
            SettingsRow("Connection", detail: detail) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(socket.status.label).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider().padding(.leading, 14)
            if socket.hasToken { saved } else { entry }
            Divider().padding(.leading, 14)
            DisclosureGroup("Set up in Slack", isExpanded: $setup) { help }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var detail: String? {
        guard let last = socket.lastEvent else { return socket.running ? "Nothing pushed yet." : "Not connected: no Slack automation is on, or no token is saved." }
        return "Last message pushed \(last.formatted(.relative(presentation: .named)))."
    }

    private var color: Color {
        switch socket.status {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .off: .secondary
        }
    }

    private var saved: some View {
        SettingsRow("App-level token", detail: result?.text) {
            HStack(spacing: 8) {
                Button("Test", action: test).disabled(testing)
                Button("Remove") {
                    socket.removeToken()
                    result = nil
                }
            }
        }
    }

    private var entry: some View {
        SettingsRow("App-level token", detail: result?.text) {
            HStack(spacing: 8) {
                SecureField("App-level token", text: $token, prompt: Text("xapp-\u{2026}")).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Save", action: save).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SlackSocketLogic.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Link("Your Slack apps\u{2026}", destination: SlackLogic.appsPage)
                Spacer()
                Button(copied ? "Copied" : "Copy Manifest") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SlackSocketLogic.manifest(), forType: .string)
                    copied = true
                }
            }
            .font(.callout)
            Text(SlackSocketLogic.manifest())
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.top, 6)
    }

    private func save() {
        do {
            try socket.save(token: token)
            token = ""
            result = nil
        } catch {
            result = ((error as? SlackError)?.message ?? error.localizedDescription, true)
        }
    }

    private func test() {
        testing = true
        result = ("Asking Slack\u{2026}", false)
        Task {
            switch await socket.test() {
            case .success: result = ("Slack accepted the token.", false)
            case .failure(let error): result = (error.message, true)
            }
            testing = false
        }
    }
}
