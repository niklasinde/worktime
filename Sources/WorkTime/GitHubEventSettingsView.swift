import SwiftUI

/// Settings › GitHub: the live stream of webhook events, so the pull requests are fetched when something happens instead of on a timer.
struct GitHubEventSettingsSection: View {
    @ObservedObject var stream: GitHubEventStream
    @State private var url: String
    @State private var repos: String
    @State private var token = ""
    @State private var result: (text: String, failed: Bool)?
    @State private var testing = false
    @FocusState private var focused: Field?

    private enum Field { case url, repos, token }

    init(stream: GitHubEventStream) {
        self.stream = stream
        _url = State(initialValue: stream.settings.url)
        _repos = State(initialValue: stream.settings.repos.joined(separator: ", "))
    }

    var body: some View {
        SettingsSection("GitHub live events", footer: "The server forwards GitHub webhook events as they happen. WorkTime refreshes only the pull "
                        + "request an event is about, and fetches the lists less often while the stream is up. The token is kept in the app's "
                        + "private secrets file and only sent to the address above.") {
            SettingsRow("Use live events", detail: stream.hasToken ? nil : "Save a token first.") {
                Toggle("Use live events", isOn: bind(\.enabled)).labelsHidden().toggleStyle(.switch).disabled(!stream.hasToken)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Connection", detail: detail) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(stream.status.label).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Stream address") {
                TextField("Stream address", text: $url).textFieldStyle(.roundedBorder).frame(width: 300).focused($focused, equals: .url)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Token", detail: result?.text) { tokenControls }
            Divider().padding(.leading, 14)
            SettingsRow("Repositories", detail: "Full names such as acme/orbit.api, separated by commas. Empty follows every repository.") {
                TextField("All repositories", text: $repos).textFieldStyle(.roundedBorder).frame(width: 300).focused($focused, equals: .repos)
            }
            Divider().padding(.leading, 14)
            SettingsRow("Events") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(GitHubEventKind.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { stream.settings.kinds.contains(kind) }, set: { setKind(kind, on: $0) }))
                    }
                }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Fetch every while connected", detail: "The lists are fetched this often as well, in case an event was missed.") {
                picker(\.streamMinutes, GitHubEventSettings.streamMinuteChoices) { $0 == 0 ? "Never" : minutes($0) }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Fetch every while disconnected") {
                picker(\.fallbackMinutes, GitHubEventSettings.fallbackMinuteChoices) { $0 == 0 ? "As under Refresh every" : minutes($0) }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Fetch faster again after") {
                picker(\.downSeconds, GitHubEventSettings.downSecondChoices) { seconds($0) }
            }
            Divider().padding(.leading, 14)
            SettingsRow("Longest wait to reconnect") {
                picker(\.backoffCap, GitHubEventSettings.backoffCapChoices) { seconds($0) }
            }
        }
        .onSubmit(commit)
        .onChange(of: focused) { commit() }
    }

    private var tokenControls: some View {
        HStack(spacing: 8) {
            if stream.hasToken {
                Button("Test connection", action: test).disabled(testing)
                Button("Remove") {
                    stream.removeToken()
                    result = nil
                }
            } else {
                SecureField("Token", text: $token).textFieldStyle(.roundedBorder).frame(width: 220).focused($focused, equals: .token)
                Button("Save", action: save).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if case .reconnecting(_, let reason?) = stream.status { parts.append(reason) }
        parts.append(stream.lastEvent.map { "Last event \($0.formatted(.relative(presentation: .named)))." } ?? "No event yet.")
        return parts.joined(separator: " ")
    }

    private var color: Color {
        switch stream.status {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .rejected: .red
        case .off: .secondary
        }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<GitHubEventSettings, Value>) -> Binding<Value> {
        Binding(get: { stream.settings[keyPath: keyPath] }, set: { value in
            var settings = stream.settings
            settings[keyPath: keyPath] = value
            stream.update(settings)
        })
    }

    private func picker(_ keyPath: WritableKeyPath<GitHubEventSettings, Int>, _ choices: [Int], label: @escaping (Int) -> String) -> some View {
        Picker("", selection: bind(keyPath)) { ForEach(choices, id: \.self) { Text(label($0)).tag($0) } }.labelsHidden().fixedSize()
    }

    private func minutes(_ value: Int) -> String { value < 60 ? "\(value) min" : "1 hour" }

    private func seconds(_ value: Int) -> String { value < 60 ? "\(value) s" : "\(value / 60) min" }

    private func setKind(_ kind: GitHubEventKind, on: Bool) {
        var settings = stream.settings
        if on { settings.kinds.insert(kind) } else { settings.kinds.remove(kind) }
        stream.update(settings)
    }

    private func commit() {
        var settings = stream.settings
        settings.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.repos = GitHubEventSettings.parseRepos(repos)
        stream.update(settings)
    }

    private func save() {
        do {
            try stream.save(token: token)
            token = ""
            result = nil
        } catch {
            result = (error.localizedDescription, true)
        }
    }

    private func test() {
        commit()
        testing = true
        result = ("Connecting\u{2026}", false)
        Task {
            let outcome = await stream.test()
            result = (outcome.message, outcome != .connected)
            testing = false
        }
    }
}
