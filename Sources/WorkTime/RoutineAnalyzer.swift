import Foundation

/// Asks Claude, through the local `claude` CLI, to look at a routine's run: one answer, no tools, no session kept.
enum RoutineAnalyzer {
    static let model = "sonnet"
    static let timeout: TimeInterval = 300

    struct Failure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    static func arguments(prompt: String) -> [String] {
        ["-p", prompt, "--output-format", "json", "--permission-mode", "dontAsk", "--no-session-persistence", "--setting-sources", "",
         "--max-budget-usd", GitHubClaude.budgetLimit, "--model", model]
    }

    static func answer(to prompt: String) async throws -> String {
        guard let cli = ClaudePlugin.findCLI() else { throw Failure(message: "The Claude CLI was not found, so the run cannot be looked at.") }
        let box = CLIResult()
        let outcome = await ClaudeProcess().run(cli: cli, arguments: arguments(prompt: prompt), directory: FileManager.default.temporaryDirectory,
                                                environment: ClaudePluginModel.environment(for: cli), timeout: timeout) { box.consume($0) }
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw Failure(message: GitHubClaude.Failure.timedOut.message) }
        guard let result = box.stream.result, !result.isError, !result.text.isEmpty else {
            throw Failure(message: GitHubClaude.failure(box.stream.result?.text ?? outcome.stderr).message)
        }
        return result.text
    }
}
