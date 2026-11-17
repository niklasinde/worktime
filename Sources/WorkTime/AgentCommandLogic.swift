import Foundation

/// A shell command in one short line: the session's scratchpad and the home folder shortened, a heredoc as the file it writes.
enum AgentCommands {
    private static let scratchpad = try! NSRegularExpression(pattern: #"/(?:private/)?tmp/claude-\d+/[^/\s]+/[^/\s]+/scratchpad"#)
    private static let heredocWrite = try! NSRegularExpression(pattern: #"\bcat\s*(>>?)\s*(?:"([^"]+)"|'([^']+)'|([^\s<>|;&]+))\s*<<-?\s*['"]?\w+['"]?"#)
    private static let heredocTee = try! NSRegularExpression(pattern: #"\btee\s+(-a\s+)?(?:"([^"]+)"|'([^']+)'|([^\s<>|;&]+))\s*<<-?\s*['"]?\w+['"]?"#)

    static func summary(_ command: String, home: String = NSHomeDirectory()) -> String {
        if let write = heredoc(command) { return "\(write.append ? "append to" : "write") \(write.file) (heredoc)" }
        return shortened(AgentLogic.firstLine(command), home: home)
    }

    /// `/private/tmp/claude-501/<project>/<session>/scratchpad/x` as `scratchpad/x`, and the home folder as `~`.
    static func shortened(_ text: String, home: String = NSHomeDirectory()) -> String {
        var text = scratchpad.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "scratchpad")
        if home.count > 1, !home.hasSuffix("/") { text = text.replacingOccurrences(of: home + "/", with: "~/") }
        return text
    }

    /// The file a `cat > file <<EOF` or `tee file <<EOF` writes, by its name, and whether it appends.
    static func heredoc(_ command: String) -> (file: String, append: Bool)? {
        let range = NSRange(command.startIndex..., in: command)
        func target(_ match: NSTextCheckingResult) -> String? {
            (2...4).lazy.compactMap { Range(match.range(at: $0), in: command).map { String(command[$0]) } }.first
        }
        if let match = heredocWrite.firstMatch(in: command, range: range), let path = target(match) {
            return (name(of: path), Range(match.range(at: 1), in: command).map { command[$0] == ">>" } ?? false)
        }
        if let match = heredocTee.firstMatch(in: command, range: range), let path = target(match) {
            return (name(of: path), match.range(at: 1).location != NSNotFound)
        }
        return nil
    }

    private static func name(of path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
}
