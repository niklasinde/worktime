import Foundation

/// One block of what a decision row shows when it is opened: a heading and its text.
struct DecisionSection: Equatable, Identifiable {
    var heading: String
    var text: String
    var monospaced = false
    var id: String { heading }
}

/// The lines of a diff around a line of the new version of a file, so a comment can be read next to the code it is about.
enum ReviewHunks {
    /// The patch's lines from `context` before to `context` after the line, with the line marked; nil when the line is in no hunk.
    static func excerpt(patch: String, line: Int, context: Int = 3, limit: Int = 12) -> String? {
        var rows: [(number: Int?, text: String)] = []
        var next = 0
        for raw in patch.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                guard let plus = raw.firstIndex(of: "+"),
                      let start = Int(raw[raw.index(after: plus)...].prefix { $0.isNumber }) else { continue }
                next = start
                rows.append((nil, raw))
            } else if raw.hasPrefix("-") {
                rows.append((nil, raw))
            } else if raw.hasPrefix("\\") {
                continue
            } else {
                rows.append((next, raw))
                next += 1
            }
        }
        guard let hit = rows.firstIndex(where: { $0.number == line }) else { return nil }
        let from = max(0, hit - context), to = min(rows.count - 1, hit + context)
        var lines = rows[from...to].enumerated().map { offset, row in
            (from + offset == hit ? "\u{25B6} " : "  ") + row.text
        }
        if lines.count > limit { lines = Array(lines.prefix(limit)) }
        return lines.joined(separator: "\n")
    }
}

/// What a decision's agent said and asked, as the row shows it in full.
struct ApprovalFacts: Equatable {
    enum Kind: Equatable { case call, roleTool, blocked }

    var kind = Kind.call
    var agent: String
    var title: String
    var body: String
    /// The call's whole input, as the permission request carries it.
    var detail = ""
    /// What the agent last said before it asked: why it wants the call.
    var context = ""
    var created: Date
}

enum DecisionDetail {
    static let describeLimit = 1500
    static let callLimit = 4000
    static let checkLimit = 12
    static let previewLines = 6

    /// The first `limit` lines of a text, and how many are left, for a "Show all N lines" button.
    static func lines(_ text: String, limit: Int = previewLines) -> (shown: String, hidden: Int) {
        let all = text.components(separatedBy: "\n")
        guard all.count > limit else { return (text, 0) }
        return (all.prefix(limit).joined(separator: "\n"), all.count - limit)
    }

    static func clipped(_ text: String, _ limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }

    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: A drafted review

    /// Everything to read before posting a review but the comments themselves: who wrote it and when, the pull request, its description
    /// and ticket, its checks and the reviewer's reasoning.
    static func review(draft: ReviewDraft, info: ReviewPRInfo, detail: GitHubPRDetail?, agent: String?, date: Date?, timeZone: TimeZone = .current) -> [DecisionSection] {
        var sections: [DecisionSection] = []
        var who = "Drafted by \(agent ?? "an agent")"
        if let date { who += " at \(time(date, timeZone: timeZone))" }
        if let sha = draft.sha { who += ", on commit \(ReviewApproval.short(sha))" }
        sections.append(DecisionSection(heading: "Who and when", text: who))

        var pull = [ReviewRows.heading(draft, info: info)]
        let meta = ReviewRows.meta(info)
        if !meta.isEmpty { pull.append(meta) }
        if let detail, !detail.base.isEmpty || !detail.head.isEmpty { pull.append("\(detail.head) \u{2192} \(detail.base)") }
        if let sha = draft.sha, let head = detail?.headOid, let problem = ReviewApproval.commitProblem(reviewed: sha, current: head) { pull.append(problem) }
        sections.append(DecisionSection(heading: "Pull request", text: pull.joined(separator: "\n")))

        if let body = detail?.body.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            sections.append(DecisionSection(heading: "Description", text: clipped(body, describeLimit)))
        }
        if let ticket = ActivityLogic.ticket(in: info.title, detail?.head) {
            sections.append(DecisionSection(heading: "Linked ticket", text: ticket))
        }
        if let checks = detail?.checks, !checks.isEmpty {
            sections.append(DecisionSection(heading: "Checks", text: checkLines(checks)))
        }
        let reasoning = ReviewDraft.untagged(draft.summary)
        if !reasoning.isEmpty { sections.append(DecisionSection(heading: "The reviewer's reasoning", text: reasoning)) }
        return sections
    }

    /// Failing checks first, then running, then the rest, each with its mark.
    static func checkLines(_ checks: [GitHubPRDetail.Check]) -> String {
        func mark(_ status: GitHubPRDetail.CheckStatus) -> String {
            switch status {
            case .failed: return "\u{2717}"
            case .running, .pending: return "\u{2026}"
            case .passed: return "\u{2713}"
            case .cancelled, .skipped: return "\u{2013}"
            }
        }
        func rank(_ status: GitHubPRDetail.CheckStatus) -> Int {
            switch status {
            case .failed: return 0
            case .running, .pending: return 1
            case .cancelled: return 2
            case .passed: return 3
            case .skipped: return 4
            }
        }
        let sorted = checks.enumerated().sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }.map(\.element)
        var lines = sorted.prefix(checkLimit).map { "\(mark($0.status)) \($0.workflow.map { "\($0) / " } ?? "")\($0.name)" }
        if sorted.count > checkLimit { lines.append("and \(sorted.count - checkLimit) more") }
        return lines.joined(separator: "\n")
    }

    // MARK: An agent that waits

    /// An approval, a tool the assistant's list leaves out, or a turn that ended after refusals.
    static func approval(_ facts: ApprovalFacts, timeZone: TimeZone = .current) -> [DecisionSection] {
        var sections = [DecisionSection(heading: "Asked by", text: "\(facts.agent) at \(time(facts.created, timeZone: timeZone))")]
        let context = facts.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { sections.append(DecisionSection(heading: "Why", text: clipped(context, describeLimit))) }
        let call = facts.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch facts.kind {
        case .call:
            sections.append(DecisionSection(heading: "The call", text: call.isEmpty ? facts.body : clipped(call, callLimit), monospaced: true))
        case .roleTool:
            sections.append(DecisionSection(heading: "What it wants", text: facts.body))
            if !call.isEmpty { sections.append(DecisionSection(heading: "The call", text: clipped(call, callLimit), monospaced: true)) }
        case .blocked:
            sections.append(DecisionSection(heading: "What it could not do", text: call.isEmpty ? facts.body : clipped(call, callLimit)))
        }
        return sections
    }

    // MARK: An automation's question

    /// The triage run's whole answer, the event it came from and what the first button sends.
    static func ask(_ notice: AgentNotice) -> [DecisionSection] {
        guard let ask = notice.ask else { return [] }
        var sections: [DecisionSection] = []
        if let event = ask.eventText?.trimmingCharacters(in: .whitespacesAndNewlines), !event.isEmpty {
            sections.append(DecisionSection(heading: "The event", text: clipped(Decisions.readable(event), describeLimit)))
        }
        if let body = notice.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            sections.append(DecisionSection(heading: "The triage answer", text: clipped(Decisions.readable(body), AutomationAsks.answerLimit)))
        }
        if let link = notice.link { sections.append(DecisionSection(heading: "Link", text: link)) }
        sections.append(DecisionSection(heading: "\u{201C}\(ask.yes)\u{201D} sends", text: clipped(ask.prompt, describeLimit)))
        return sections
    }
}

/// Which rows of the decision list are open and which has the keyboard.
struct DecisionExpansion: Equatable {
    private(set) var expanded: Set<String> = []
    private(set) var focus: String?

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    mutating func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        focus = id
    }

    mutating func setFocus(_ id: String?) { focus = id }

    /// Moves the keyboard focus up or down the rows, staying on the first or last; with none it starts at the first.
    mutating func moveFocus(_ step: Int, in ids: [String]) {
        guard !ids.isEmpty else { focus = nil; return }
        guard let current = focus.flatMap({ ids.firstIndex(of: $0) }) else { focus = ids.first; return }
        focus = ids[min(max(current + step, 0), ids.count - 1)]
    }

    /// Space or Return: opens or closes the focused row, returning it.
    @discardableResult
    mutating func activate() -> String? {
        guard let focus else { return nil }
        toggle(focus)
        return focus
    }

    /// Forgets rows that are gone, so a row that comes back later starts closed.
    mutating func prune(to ids: [String]) {
        let live = Set(ids)
        expanded.formIntersection(live)
        if let focus, !live.contains(focus) { self.focus = nil }
    }
}

/// The ids the decision list's rows carry, one family for each kind.
enum DecisionIDs {
    static func notice(_ id: String) -> String { "notice:" + id }
    static func review(_ id: String) -> String { "review:" + id }
    static func approval(_ id: String) -> String { "approval:" + id }
}
