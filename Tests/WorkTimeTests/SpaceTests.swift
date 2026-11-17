import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_792_300_000)
private let review = Space(id: "review", name: "Review", icon: "eye", color: "orange")
private let develop = Space(id: "develop", name: "Develop", icon: "hammer", color: "blue")
private let verify = Space(id: "verify", name: "Verify", icon: "checkmark.seal", color: "green")
private let lanes = [review, develop, verify]
private let developerKey = Assistants.key(workspace: "work", slug: "developer")
private let verifierKey = Assistants.key(workspace: "work", slug: "verifier")
private let reviewerKey = Assistants.key(workspace: "work", slug: "reviewer")

private func topicKey(_ n: Int) -> String { TopicAgents.prefix + "00000000-0000-0000-0000-00000000000\(n)" }

private func session(_ n: Int, ticket: String, roleKey: String, spaces: [String]? = nil, result: String? = nil, updated: TimeInterval = 0,
                     status: AgentState.Status = .idle) -> AgentState {
    var state = AgentState(key: topicKey(n), title: "\(ticket) session", status: status, updatedAt: now.addingTimeInterval(updated))
    state.jiraKey = ticket
    state.roleKey = roleKey
    state.role = Assistants.parse(key: roleKey)?.slug.capitalized
    state.spaces = spaces
    state.lastResult = result
    return state
}

private func pullRequest(_ number: Int, spaces: [String]? = nil, status: AgentState.Status = .idle) -> AgentState {
    let url = "https://github.com/acme-com/api/pull/\(number)"
    var state = AgentState(key: url, title: "api#\(number)", prURL: url, status: status)
    state.spaces = spaces
    return state
}

private func assistant(_ slug: String, spaces: [String], usable: Bool = true) -> AssistantEntry {
    var role = AssistantRole(slug: slug, name: slug.capitalized, summary: "Does \(slug).", spaces: spaces)
    if !usable { role.problems = [AssistantProblem(line: nil, message: "broken")] }
    return AssistantEntry(workspace: "work", role: role)
}

private func routine(_ name: String, spaces: [String]?) -> Routine {
    var routine = Routine(id: UUID().uuidString, name: name, prompt: "Do it", workspace: "work", schedule: RoutineSchedule(kind: .weekdays), created: now)
    routine.spaces = spaces
    return routine
}

private func roleFile(_ extra: String) -> String {
    "---\nname: Verifier\ndescription: Verifies it.\n\(extra)---\n\nBody.\n"
}

let spaceTests: [(name: String, run: () throws -> Void)] = [
    ("spaces: a role file's spaces parse from an inline or block list, drop repeats and survive serialising", {
        check(Assistants.parse(slug: "v", text: roleFile("spaces: [review, verify, review]\n")).spaces == ["review", "verify"], "inline")
        check(Assistants.parse(slug: "v", text: roleFile("spaces:\n  - review\n  - \"verify\"\n")).spaces == ["review", "verify"], "block")
        check(Assistants.parse(slug: "v", text: roleFile("spaces: verify\n")).spaces == ["verify"], "bare")
        check(Assistants.parse(slug: "v", text: roleFile("")).spaces.isEmpty, "none")
        let parsed = Assistants.parse(slug: "v", text: roleFile("spaces: [review, verify]\n"))
        check(parsed.isUsable, "usable \(parsed.problems)")
        let text = Assistants.serialise(parsed)
        check(text.contains("spaces: [review, verify]"), text)
        check(Assistants.parse(slug: "v", text: text) == parsed, "round trip")
        check(!Assistants.serialise(Assistants.parse(slug: "v", text: roleFile(""))).contains("spaces"), "left out when empty")
        check(Assistants.parse(slug: "v", text: roleFile("spaces: []\n")).isUsable, "empty list")
    }),
    ("spaces: editing a role file by hand keeps its spaces line", {
        let text = roleFile("tools: [jira_issue]\nspaces: [review]\n")
        check(Assistants.renamed(text, to: "Checker").contains("spaces: [review]"), "rename")
        let added = RoleTools.adding("github_pr", to: text) ?? ""
        check(Assistants.parse(slug: "v", text: added).spaces == ["review"] && Assistants.parse(slug: "v", text: added).tools == ["jira_issue", "github_pr"], added)
        let updated = AssistantRequests.updated(Assistants.parse(slug: "v", text: text), with: AssistantDraft(summary: "Verifies more."), tools: ["jira_issue"])
        guard case .success(let role) = updated else { return check(false, "update") }
        check(role.spaces == ["review"], "an update through the tools")
    }),
    ("spaces: ids a role file names that the workspace has no space for are kept and warned about", {
        let role = Assistants.parse(slug: "v", text: roleFile("spaces: [review, qa, qa, verify]\n"))
        let split = Spaces.split(role.spaces, in: lanes)
        check(split.known == ["review", "verify"] && split.unknown == ["qa"], "\(split)")
        let warnings = Spaces.warnings(for: role, in: lanes)
        check(warnings.count == 1 && warnings[0].message.contains("qa") && warnings[0].message.contains("review, develop, verify"), "\(warnings.map(\.message))")
        check(role.isUsable, "a warning does not break the role")
        check(Spaces.warnings(for: role, in: []).first?.message.contains("no spaces") == true, "a workspace without spaces")
        check(Spaces.warnings(for: Assistants.parse(slug: "v", text: roleFile("spaces: [review]\n")), in: lanes).isEmpty, "none when all known")
    }),
    ("spaces: a workspace file without spaces or tags loads as it did, and one with them round-trips", {
        let old = """
            {"workspaces":[{"id":"work","name":"Work","symbol":"briefcase.fill","color":"blue","roots":["~/git"],"githubOwners":[],"jiraProjects":["ACME"],"extraFiles":[]}],
             "overrides":{"https://github.com/acme-com/api/pull/1":"work"}}
            """
        let file = Workspaces.decode(Data(old.utf8))
        check(file.workspaces.count == 1 && file.workspaces[0].spaces.isEmpty && file.spaceTags.isEmpty, "no spaces")
        check(file.overrides.count == 1, "overrides kept")
        let encoded = String(decoding: Workspaces.encode(file), as: UTF8.self)
        check(!encoded.contains("\"spaces\""), "a workspace without spaces writes none")
        var made = file
        made.workspaces[0].spaces = lanes
        made.spaceTags = [topicKey(1): ["verify"]]
        check(Workspaces.decode(Workspaces.encode(made)) == made, "round trip")
        let lenient = Workspaces.decode(Data(old.replacingOccurrences(of: "\"extraFiles\":[]", with: "\"extraFiles\":[],\"spaces\":[{\"id\":\"qa\"}]").utf8))
        check(lenient.workspaces[0].spaces == [Space(id: "qa", name: "qa")], "name, icon and colour may be left out")
    }),
    ("spaces: sessions, routines, requests and asks saved before spaces load unchanged", {
        let state = AgentState(key: topicKey(1), title: "PROJ-1", status: .idle)
        let data = AgentOverview.encode([state], now: now)
        check(!String(decoding: data, as: UTF8.self).contains("spaces"), "no key written")
        check(AgentOverview.decode(data)?.agents == [state], "agents.json")
        var tagged = state
        tagged.spaces = ["review"]
        check(AgentOverview.decode(AgentOverview.encode([tagged], now: now))?.agents == [tagged], "with spaces")
        let routines = Routines.decode(Routines.encode([routine("Sweep", spaces: nil)]))
        check(routines.count == 1 && routines[0].spaces == nil, "routine")
        check(Routines.decode(Routines.encode([routine("Sweep", spaces: ["review"])]))[0].spaces == ["review"], "routine with spaces")
        let request = AgentInbox.request(agent: developerKey, text: "Go", now: now, ticket: "ACME-1", space: "verify")
        guard case .success(let made) = request else { return check(false, "request") }
        check(AgentInbox.decode(AgentInbox.Request.self, from: AgentInbox.encode(made))?.space == "verify", "space travels")
        let plain = AgentInbox.decode(AgentInbox.Request.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"agent\":\"\(developerKey)\",\"text\":\"x\",\"created\":\"2026-11-17T10:00:00Z\"}".utf8))
        check(plain != nil && plain?.space == nil, "an old request")
    }),
    ("spaces: a session starts in its assistant's spaces, the user's tags replace them, a pull request agent starts in none", {
        let roleSpaces: (String) -> [String] = { $0 == developerKey ? ["develop"] : $0 == verifierKey ? ["review", "verify"] : [] }
        func spaces(_ state: AgentState, tags: [String: [String]] = [:], in list: [Space] = lanes) -> [String]? {
            Spaces.spaces(of: state, in: list, tags: tags, assistantSpaces: roleSpaces)
        }
        let developer = session(1, ticket: "ACME-1", roleKey: developerKey), verifier = session(2, ticket: "ACME-1", roleKey: verifierKey)
        check(spaces(developer) == ["develop"], "default from the assistant")
        check(spaces(verifier) == ["review", "verify"], "several")
        check(spaces(pullRequest(1)) == nil, "a pull request agent: none")
        check(spaces(developer, tags: [developer.key: ["verify", "develop"]]) == ["develop", "verify"], "tags replace and follow the order of the spaces")
        check(spaces(developer, tags: [developer.key: []]) == nil, "an empty tag list means none")
        check(spaces(pullRequest(1), tags: [pullRequest(1).key: ["review"]]) == ["review"], "tagged pull request")
        check(spaces(developer, tags: [developer.key: ["gone"]]) == nil, "an unknown id is dropped")
        check(spaces(developer, in: []) == nil, "a workspace without spaces")
        var assistantRow = AgentState(key: verifierKey, title: "Verifier", status: .idle)
        assistantRow.kind = "assistant"
        check(spaces(assistantRow, tags: [verifierKey: ["develop"]]) == ["review", "verify"], "an assistant takes its file's spaces")
        check(spaces(AgentState(key: Workspaces.mainKey("work"), title: "Main", status: .idle)) == nil, "Main is in none")
        check(Spaces.effective(tags: nil, assistant: ["verify", "qa"], in: lanes) == ["verify"], "effective")
    }),
    ("spaces: filtering keeps a space's agents and Main, and counts cover sessions, assistants and routines", {
        let main = AgentState(key: Workspaces.mainKey("work"), title: "Main", status: .idle)
        let a = session(1, ticket: "ACME-1", roleKey: developerKey, spaces: ["develop"])
        let b = session(2, ticket: "ACME-2", roleKey: verifierKey, spaces: ["review", "verify"], status: .waiting)
        let c = pullRequest(3)
        var closed = session(4, ticket: "ACME-3", roleKey: verifierKey, spaces: ["verify"])
        closed.archived = true
        let all = [main, a, b, c, closed]
        check(Spaces.filter(all, space: nil) == all, "no space: everything")
        check(Spaces.filter(all, space: "verify").map(\.key) == [main.key, b.key, closed.key], "verify")
        check(Spaces.filter(all, space: "develop").map(\.key) == [main.key, a.key], "develop")
        let counts = Spaces.counts(states: all, routines: [routine("Sweep", spaces: ["review"]), routine("Loose", spaces: nil)], spaces: lanes)
        check(counts[Spaces.all] == 5 && counts["review"] == 2 && counts["develop"] == 1 && counts["verify"] == 1, "\(counts)")
        check(Spaces.filter([routine("Sweep", spaces: ["review"]), routine("Loose", spaces: nil)], space: "review").map(\.name) == ["Sweep"], "routines")
        check(Spaces.filter([routine("Loose", spaces: nil)], space: "review").isEmpty, "an untagged routine shows only under All")
        check(Spaces.needsUser(all, space: "review") && Spaces.needsUser(all, space: nil), "a waiting session lights its spaces")
        check(!Spaces.needsUser(all, space: "develop"), "develop waits for nothing")
        check(!Spaces.needsUser([closed, main], space: nil), "closed sessions and Main do not count")
    }),
    ("spaces: a ticket group shows in every space any of its sessions is in, once, with all its sessions", {
        let projects: Set<String> = ["ACME"]
        let developer = session(1, ticket: "ACME-1", roleKey: developerKey, spaces: ["develop"])
        let verifier = session(2, ticket: "ACME-1", roleKey: verifierKey, spaces: ["verify"])
        let both = session(3, ticket: "ACME-2", roleKey: verifierKey, spaces: ["develop", "verify"])
        let other = session(4, ticket: "ACME-3", roleKey: reviewerKey, spaces: ["review"])
        let agents = [developer, verifier, both, other]
        func rows(_ space: String?) -> [TicketRow] { TicketGrouping.rows(Spaces.related(agents, space: space, projects: projects), projects: projects) }
        func groups(_ space: String?) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: rows(space).compactMap { row -> (String, Int)? in
                if case .group(let group) = row { return (group.subject.label, group.live.count) } else { return nil }
            })
        }
        check(groups("develop") == ["ACME-1": 2, "ACME-2": 1], "develop: ACME-1 keeps its verifier \(groups("develop"))")
        check(groups("verify") == ["ACME-1": 2, "ACME-2": 1], "verify: the same ticket again, not twice in a space")
        check(groups("review") == ["ACME-3": 1], "review")
        check(rows("develop").count == 2, "one row per group")
        check(rows(nil).count == 3, "all")
        check(Spaces.related(agents, space: "none", projects: projects).isEmpty, "a space with nothing")
        let loose = pullRequest(9, spaces: ["review"])
        check(Spaces.related(agents + [loose], space: "review", projects: projects).map(\.key) == [other.key, loose.key], "a pull request agent on its own")
    }),
    ("spaces: tagging adds a space once and a toggle takes it out", {
        check(Spaces.adding("verify", to: ["develop"]) == ["develop", "verify"], "added")
        check(Spaces.adding("verify", to: ["verify"]) == ["verify"], "not twice")
        check(Spaces.toggling("review", in: ["review", "verify"]) == ["verify"] && Spaces.toggling("review", in: ["verify"]) == ["verify", "review"], "toggled")
        guard case .success(let found) = Spaces.resolve(" verify ", in: lanes), case .success(let byName) = Spaces.resolve("REVIEW", in: lanes) else { return check(false, "resolve") }
        check(found == verify && byName == review, "by id or name")
        guard case .failure(let error) = Spaces.resolve("qa", in: lanes) else { return check(false, "unknown") }
        check(error.message.contains("review, develop, verify"), error.message)
        guard case .failure(let none) = Spaces.resolve("qa", in: []) else { return check(false, "no spaces") }
        check(none.message.contains("no spaces"), none.message)
        check(Spaces.id(for: "Needs Review", taken: ["needs-review"]) != "needs-review" && Spaces.id(for: "Verify", taken: []) == "verify", "ids")
    }),
    ("spaces: the next assistant is the first usable one meant for the target space that is not the current one", {
        let developer = assistant("developer", spaces: ["develop"]), verifier = assistant("verifier", spaces: ["review", "verify"])
        let second = assistant("tester", spaces: ["verify"]), broken = assistant("broken", spaces: ["verify"], usable: false)
        let entries = [developer, broken, verifier, second]
        check(Spaces.nextAssistant(for: "verify", excluding: developer.key, in: entries)?.key == verifier.key, "skips the broken one")
        check(Spaces.nextAssistant(for: "verify", excluding: verifier.key, in: entries)?.key == second.key, "not the current one")
        check(Spaces.nextAssistant(for: "develop", excluding: developer.key, in: entries) == nil, "nobody else")
        check(Spaces.nextAssistant(for: "qa", excluding: nil, in: entries) == nil, "no one for it")
    }),
    ("spaces: a handoff from Developer to Verify names the ticket, carries the outcome and picks the next assistant", {
        let done = session(1, ticket: "ACME-1", roleKey: developerKey, spaces: ["develop"], result: "ACME-1 done: PR is up.\nTests pass.", updated: 60)
        let older = session(2, ticket: "ACME-1", roleKey: reviewerKey, spaces: ["review"], result: "Old note", updated: 0)
        let handoff = Spaces.handoff(states: [older, done], to: verify, subject: .ticket("ACME-1"), entries: [assistant("developer", spaces: ["develop"]), assistant("verifier", spaces: ["verify"])])
        check(handoff.keys == [older.key, done.key] && handoff.space == verify, "tags both sessions")
        check(handoff.assistant?.key == verifierKey, "the verifier")
        check(handoff.prompt.hasPrefix("Verify ACME-1."), handoff.prompt)
        check(handoff.prompt.contains("What Developer reported: ACME-1 done: PR is up. / Tests pass."), handoff.prompt)
        let again = Spaces.handoff(states: [done], to: develop, subject: .ticket("ACME-1"), entries: [assistant("developer", spaces: ["develop"])])
        check(again.assistant == nil, "the current assistant is not offered again")
        let bare = Spaces.handoffPrompt(space: review, subject: .pullRequest("https://github.com/acme-com/api/pull/7"), from: nil, outcome: nil)
        check(bare == "Review api#7.", bare)
        var closed = done
        closed.archived = true
        check(Spaces.handoff(states: [closed, older], to: verify, subject: nil, entries: []).keys == [older.key], "closed sessions are not tagged")
    }),
    ("spaces: the chosen space is kept per workspace and forgotten when its space is removed", {
        var raw = Spaces.choosing("verify", workspace: "work", in: "")
        raw = Spaces.choosing("review", workspace: "personal", in: raw)
        check(Spaces.chosen(raw, workspace: "work", in: lanes) == "verify" && Spaces.chosen(raw, workspace: "personal", in: lanes) == "review", raw)
        check(Spaces.chosen(raw, workspace: "work", in: [review]) == nil, "removed")
        raw = Spaces.choosing(nil, workspace: "work", in: raw)
        check(Spaces.chosen(raw, workspace: "work", in: lanes) == nil && Spaces.chosen(raw, workspace: "personal", in: lanes) == "review", "All")
        check(Spaces.chosen("", workspace: "work", in: lanes) == nil, "nothing saved")
    }),
    ("spaces: agents_overview filters by space id or name and lists each row's spaces", {
        let a = session(1, ticket: "ACME-1", roleKey: developerKey, spaces: ["develop"])
        let b = session(2, ticket: "ACME-2", roleKey: verifierKey, spaces: ["review", "verify"])
        let filter = try AgentFilter(["space": "Verify"], spaces: lanes)
        check(filter.space == "verify" && filter.applied.contains { $0.contains("verify") }, "resolved \(filter.applied)")
        check([a, b].filter(filter.matches).map(\.key) == [b.key], "matches")
        do {
            _ = try AgentFilter(["space": "qa"], spaces: lanes)
            check(false, "an unknown space is refused")
        } catch { check(error.localizedDescription.contains("qa"), "refused: \(error)") }
        let text = AgentOverview.markdown(AgentOverview.File(written: now, agents: [b]), now: now, spaces: lanes)
        check(text.contains("spaces: Review, Verify"), text)
        check(!AgentOverview.markdown(AgentOverview.File(written: now, agents: [session(3, ticket: "ACME-3", roleKey: developerKey)]), now: now, spaces: lanes).contains("spaces:"), "none listed when none")
    }),
    ("spaces: Main is told to pass space for a handoff", {
        check(TicketSessions.mainNote.contains("space") && TicketSessions.mainNote.contains("agents_overview with space"), "the note")
        check(AgentLogic.mainBasePrompt.contains(TicketSessions.mainNote), "in Main's prompt")
    }),
]
