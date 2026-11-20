import Foundation

/// Titles of tickets and pull requests found in a transcript, so the Related list can name them without asking Jira or GitHub.
enum SessionTitles {
    static let titleLimit = 140
    static let lineLimit = 600
    static let resultLimit = 60_000
    private static let ticketLine = #/^\s*(?:#{1,3}\s+|[-*]\s+)((?:[a-z][a-z ]{0,28}[a-z]\s+)?)([A-Z][A-Z0-9]{1,9})-([1-9][0-9]{0,6})\s+(\S.*)$/#
    private static let pullRequestLine = #/^\s*(?:#{1,3}\s+|[-*]\s+)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([1-9][0-9]{0,6})\s+(\S.*)$/#
    private static let pullRequestStateLine = #/^\s*-\s*State:\s*(open|merged|closed)(,\s*draft)?/#
    private static let titleHint = #/(?:^|[^A-Za-z0-9_])([A-Z][A-Z0-9]{1,9})-([1-9][0-9]{0,6})(?::[ \t]+|[ \t]+[-\u{2013}\u{2014}\u{00B7}][ \t]+)([^\n]{8,300})/#

    /// What a tool's answer says about the tickets and pull requests it names: in WorkTime's own Markdown (`jira_issue`, `jira_search`,
    /// `github_pr`, `github_prs`) and in the JSON of `gh` and Jira. `call` is what the tool was asked, which says which pull request
    /// an answer without an address is about.
    static func structured(call: String, result: String, projects: Set<String>) -> [SessionRef: SessionRefInfo] {
        let result = result.utf8.count > resultLimit ? String(result.prefix(resultLimit)) : result
        var found = json(result, call: call, projects: projects)
        for (ref, info) in markdown(result, projects: projects) { found[ref] = found[ref]?.overlaid(by: info) ?? info }
        return found
    }

    // MARK: Markdown

    private static func markdown(_ text: String, projects: Set<String>) -> [SessionRef: SessionRefInfo] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineLimit).map(String.init)
        var found: [SessionRef: SessionRefInfo] = [:]
        for (index, line) in lines.enumerated() {
            if let match = line.firstMatch(of: ticketLine),
               projects.contains(String(match.2)) {
                let relation = !match.1.isEmpty
                var rest = String(match.4)
                var status: String?
                if let dot = rest.range(of: " \u{00B7} ") {
                    status = clean(String(rest[dot.upperBound...]).components(separatedBy: " \u{00B7} ").first ?? "", limit: 40)
                    rest = String(rest[..<dot.lowerBound])
                } else if relation, let open = rest.range(of: " (", options: .backwards), rest.hasSuffix(")") {
                    status = clean(String(rest[open.upperBound...].dropLast()), limit: 40)
                    rest = String(rest[..<open.lowerBound])
                }
                let title = clean(rest, limit: titleLimit)
                if !title.isEmpty {
                    found[.jira("\(match.2)-\(match.3)")] = SessionRefInfo(title: title, status: status?.isEmpty == true ? nil : status)
                }
            } else if let match = line.firstMatch(of: pullRequestLine) {
                let title = clean(String(match.3), limit: titleLimit)
                guard !title.isEmpty, let number = Int(match.2) else { continue }
                var info = SessionRefInfo(title: title)
                (info.state, info.isDraft) = pullRequestState(after: lines[(index + 1)...].prefix(8))
                found[.pullRequest(repo: String(match.1), number: number)] = info
            }
        }
        return found
    }

    /// The state in the lines under a pull request: `- State: merged, draft, by x` in a detail, or the facts line of a list entry,
    /// which names the state only when it is not open.
    private static func pullRequestState(after lines: ArraySlice<String>) -> (state: String?, isDraft: Bool) {
        let lines = Array(lines)
        for line in lines {
            if let match = line.firstMatch(of: pullRequestStateLine) { return (String(match.1), match.2 != nil) }
        }
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("https://") else { return (nil, false) }
        let facts = lines[1].components(separatedBy: " \u{00B7} ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard facts.contains(where: { $0.hasPrefix("by ") }) else { return (nil, false) }
        let state = facts.first { $0 == "merged" || $0 == "closed" } ?? "open"
        return (state, facts.contains("draft"))
    }

    // MARK: JSON

    private static func json(_ text: String, call: String, projects: Set<String>) -> [SessionRef: SessionRefInfo] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return [:] }
        let asked = SessionLinks.references(in: call, projects: projects).compactMap { ref in ref.target.map { (ref, $0.number) } }
        var found: [SessionRef: SessionRefInfo] = [:]
        walk(object, depth: 0, asked: asked, projects: projects, into: &found)
        return found
    }

    private static func walk(_ node: Any, depth: Int, asked: [(SessionRef, Int)], projects: Set<String>, into found: inout [SessionRef: SessionRefInfo]) {
        guard depth < 4, found.count < 40 else { return }
        if let array = node as? [Any] {
            for element in array.prefix(40) { walk(element, depth: depth + 1, asked: asked, projects: projects, into: &found) }
        } else if let dictionary = node as? [String: Any] {
            if let (ref, info) = pullRequest(dictionary, depth: depth, asked: asked) ?? ticket(dictionary, projects: projects) {
                found[ref] = info
            }
            for (key, value) in dictionary where key != "fields" && key != "labels" {
                walk(value, depth: depth + 1, asked: asked, projects: projects, into: &found)
            }
        }
    }

    /// A pull request as `gh pr view --json` or the GitHub API shows it: by its address, else by its number among those the call named,
    /// else the one pull request the call named when the answer is a single object.
    private static func pullRequest(_ dictionary: [String: Any], depth: Int, asked: [(SessionRef, Int)]) -> (SessionRef, SessionRefInfo)? {
        guard let title = (dictionary["title"] as? String).map({ clean($0, limit: titleLimit) }), !title.isEmpty else { return nil }
        let ref: SessionRef
        if let url = dictionary["url"] as? String, let target = GitHubLink.pullRequest(at: url) {
            ref = SessionRef(target)
        } else if let number = dictionary["number"] as? Int {
            let named = asked.filter { $0.1 == number }
            guard named.count == 1 else { return nil }
            ref = named[0].0
        } else if depth == 0, asked.count == 1, dictionary["key"] == nil {
            ref = asked[0].0
        } else {
            return nil
        }
        var info = SessionRefInfo(title: title)
        let merged = dictionary["merged"] as? Bool == true || (dictionary["mergedAt"] as? String).map { !$0.isEmpty } == true
        if merged {
            info.state = "merged"
        } else if let state = (dictionary["state"] as? String)?.lowercased(), ["open", "merged", "closed"].contains(state) {
            info.state = state
        }
        info.isDraft = dictionary["isDraft"] as? Bool ?? dictionary["draft"] as? Bool ?? false
        return (ref, info)
    }

    /// A ticket as Jira's REST API shows it: its key and the summary and status in `fields`.
    private static func ticket(_ dictionary: [String: Any], projects: Set<String>) -> (SessionRef, SessionRefInfo)? {
        guard let key = dictionary["key"] as? String, let fields = dictionary["fields"] as? [String: Any],
              let summary = (fields["summary"] as? String).map({ clean($0, limit: titleLimit) }), !summary.isEmpty,
              let dash = key.lastIndex(of: "-"), projects.contains(String(key[..<dash])) else { return nil }
        let status = fields["status"] as? [String: Any]
        let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String
        return (.jira(key), SessionRefInfo(title: summary, status: status?["name"] as? String, category: category))
    }

    // MARK: Titles in running text

    /// A ticket named with its title: `ACME-12: Export the list`, `ACME-12 - Export the list` or a commit's `abc1234 ACME-12: Export`.
    /// Nothing says the title is the ticket's, so these only fill in until the ticket is looked up.
    static func hints(in text: String, projects: Set<String>) -> [SessionRef: String] {
        guard !projects.isEmpty else { return [:] }
        let text = text.utf8.count > SessionLinks.textLimit ? String(text.prefix(SessionLinks.textLimit)) : text
        var found: [SessionRef: String] = [:]
        for match in text.matches(of: titleHint)
        where projects.contains(String(match.1)) {
            let ref = SessionRef.jira("\(match.1)-\(match.2)")
            let title = clean(String(match.3), limit: titleLimit)
            guard found[ref] == nil, isTitle(title) else { continue }
            found[ref] = title
        }
        return found
    }

    private static func isTitle(_ text: String) -> Bool {
        text.count >= 8 && text.contains(where: \.isLetter) && !text.hasPrefix("http") && !text.hasPrefix("/") && !text.hasPrefix("~")
    }

    /// A title as one line of plain text: no Markdown around it, links reduced to their words, nothing after a bare link, cut at `limit`.
    static func clean(_ text: String, limit: Int) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        if let range = text.range(of: " http") { text = String(text[..<range.lowerBound]) }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t\"'"))
        return text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : text
    }
}
