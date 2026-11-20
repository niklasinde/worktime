import AppKit
import Foundation

enum CodexSetup {
    enum Status: Equatable { case missing, signedIn(String), signedOut(String) }
    struct Model: Identifiable, Equatable, Codable {
        let id: String
        let name: String
        let isDefault: Bool
    }
    struct Details: Equatable {
        let account: String?
        let models: [Model]
    }

    static let fallbackModels = [
        Model(id: "", name: "Codex default", isDefault: true),
        Model(id: "gpt-6.2-sol", name: "gpt-6.2-sol", isDefault: false),
        Model(id: "gpt-6.1-sol", name: "gpt-6.1-sol", isDefault: false),
    ]
    static let modelsKey = "agentCodexDiscoveredModels"

    static func availableModels(defaults: UserDefaults = .standard) -> [Model] {
        guard let data = defaults.data(forKey: modelsKey), let models = try? JSONDecoder().decode([Model].self, from: data), !models.isEmpty else { return fallbackModels }
        return models
    }

    static func models(_ models: [Model], including selected: String?) -> [Model] {
        guard let selected, !models.contains(where: { $0.id == selected }) else { return models }
        return models + [Model(id: selected, name: selected.isEmpty ? "Codex default" : selected, isDefault: false)]
    }

    static func saveModels(_ models: [Model], defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(models), forKey: modelsKey)
    }

    static func findCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        let known = [home.appendingPathComponent(".local/bin/codex"), URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                     URL(fileURLWithPath: "/usr/local/bin/codex"), URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")]
        return (path + known).first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func status(cli: URL?, output: String?) -> Status {
        guard cli != nil else { return .missing }
        let text = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.lowercased().hasPrefix("logged in") ? .signedIn(text) : .signedOut(text.isEmpty ? "Run `codex login` in Terminal." : text)
    }

    static func details(from messages: [[String: Any]]) -> Details? {
        var account: String?
        var models: [Model]?
        for message in messages {
            guard let id = message["id"] as? Int, let result = message["result"] as? [String: Any] else { continue }
            if id == 2 {
                let value = (result["account"] as? [String: Any]) ?? result
                let email = value["email"] as? String
                let plan = value["planType"] as? String
                let parts = [email, plan].compactMap { $0 }
                if !parts.isEmpty { account = parts.joined(separator: " · ") }
            }
            if id == 3 {
                let values = (result["data"] as? [[String: Any]]) ?? (result["models"] as? [[String: Any]]) ?? []
                let parsed = values.compactMap { value -> Model? in
                    guard let id = value["id"] as? String else { return nil }
                    return Model(id: id, name: (value["displayName"] as? String) ?? id, isDefault: (value["isDefault"] as? Bool) ?? false)
                }
                if !parsed.isEmpty { models = parsed }
            }
        }
        guard account != nil || models != nil else { return nil }
        return Details(account: account, models: models ?? fallbackModels)
    }

    static func readDetails(cli: URL, environment: [String: String]) -> Details? {
        let process = Process(); process.executableURL = cli; process.arguments = ["app-server", "--stdio"]
        var environment = environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); let lock = NSLock()
        var buffer = Data(); var messages: [[String: Any]] = []; var sentQueries = false; var complete = false
        func write(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                messages.append(object)
                if object["id"] as? Int == 1, !sentQueries {
                    sentQueries = true
                    write(["method": "initialized", "params": [:]])
                    write(["id": 2, "method": "account/read", "params": [:]])
                    write(["id": 3, "method": "model/list", "params": [:]])
                }
                if !complete, messages.contains(where: { $0["id"] as? Int == 2 }) && messages.contains(where: { $0["id"] as? Int == 3 }) {
                    complete = true; done.signal()
                }
            }
        }
        guard (try? process.run()) != nil else { output.fileHandleForReading.readabilityHandler = nil; return nil }
        write(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "worktime", "version": "1"]]])
        _ = done.wait(timeout: .now() + 5)
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        lock.lock(); defer { lock.unlock() }
        return details(from: messages)
    }
}

@MainActor
final class CodexSetupModel: ObservableObject {
    @Published private(set) var cli: URL?
    @Published private(set) var status = CodexSetup.Status.missing
    @Published private(set) var checking = false
    @Published private(set) var account: String?
    @Published private(set) var models = CodexSetup.availableModels()

    func refresh() {
        cli = CodexSetup.findCLI()
        guard let cli else { status = .missing; return }
        checking = true
        Task {
            let result = await Task.detached { () -> (String, CodexSetup.Details?) in
                let process = Process(); process.executableURL = cli; process.arguments = ["login", "status"]
                process.environment = ClaudePluginModel.environment(for: cli)
                let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return ("Could not run Codex.", nil) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                let status = CodexSetup.status(cli: cli, output: output)
                let details: CodexSetup.Details?
                if case .signedIn = status { details = CodexSetup.readDetails(cli: cli, environment: ClaudePluginModel.environment(for: cli)) } else { details = nil }
                return (output, details)
            }.value
            status = CodexSetup.status(cli: cli, output: result.0)
            account = result.1?.account
            models = result.1?.models ?? CodexSetup.fallbackModels
            CodexSetup.saveModels(models)
            checking = false
        }
    }

    func copyLoginCommand() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex login", forType: .string) }
    func copyInstallCommand() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("npm install -g @openai/codex", forType: .string) }
    func copySwitchAccountCommand() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("codex logout && codex login", forType: .string) }
}
