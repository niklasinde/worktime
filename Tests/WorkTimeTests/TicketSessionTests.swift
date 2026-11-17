import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let verifier = AssistantEntry(workspace: "work", role: AssistantRole(slug: "verifier", name: "Verifier", summary: "Checks a ticket."))
private let developer = AssistantEntry(workspace: "work", role: AssistantRole(slug: "developer", name: "Developer", summary: "Builds."))

private func session(_ id: String, _ entry: AssistantEntry = verifier, ticket: String = "ACME-1", created: TimeInterval = 0, archived: Bool = false) -> TopicAgent {
    var topic = TicketSessions.make(entry: entry, subject: .ticket(ticket), folder: "/tmp/\(entry.role.slug)", id: id, now: now.addingTimeInterval(created))
    topic.archived = archived
    return topic
}

private func defaults() -> UserDefaults {
    let suite = "ticket-sessions-\(UUID().uuidString)"
    let made = UserDefaults(suiteName: suite)!
    made.removePersistentDomain(forName: suite)
    return made
}

private func state(_ key: String, title: String = "t", ticket: String? = nil, roleKey: String? = nil, role: String? = nil, pr: String? = nil,
                   status: AgentState.Status = .idle, updated: TimeInterval = 0) -> AgentState {
    var state = AgentState(key: key, title: title, prURL: pr, status: status, updatedAt: now.addingTimeInterval(updated))
    state.jiraKey = ticket
    state.roleKey = roleKey
    state.role = role
    return state
}

private let id1 = "11111111-1111-1111-1111-111111111111"
private let id2 = "22222222-2222-2222-2222-222222222222"
private let id3 = "33333333-3333-3333-3333-333333333333"

let ticketSessionTests: [(name: String, run: () throws -> Void)] = [
    ("tickets: a key is normalised and checked against the workspace's Jira projects", {
        check(TicketSessions.ticket(" acme-12 ", projects: ["ACME"]) == .success("ACME-12"), "normalised")
        check(TicketSessions.ticket("ACME-12", projects: []) == .success("ACME-12"), "no projects: any")
        check(TicketSessions.ticket("", projects: ["ACME"]) == .success(nil) && TicketSessions.ticket(nil, projects: ["ACME"]) == .success(nil), "none given")
        guard case .failure(let other) = TicketSessions.ticket("OTHER-1", projects: ["acme", "ISD"]) else { return check(false, "other project") }
        check(other.message.contains("ACME, ISD"), other.message)
        guard case .failure(let bad) = TicketSessions.ticket("not a key", projects: []) else { return check(false, "not a key") }
        check(bad.message.contains("not a key"), bad.message)
        check(TicketSessions.ticket("https://acme.atlassian.net/browse/ACME-9", projects: ["ACME"]) == .success("ACME-9"), "a link")
    }),
    ("tickets: a session is a topic for the ticket carrying the assistant, named by ticket and role", {
        let made = session(id1)
        check(made.name == "ACME-1 \u{00B7} Verifier" && made.jiraKey == "ACME-1" && made.assistant == verifier.key, "\(made)")
        check(made.kind == .ticket && made.isRoleSession && made.key == "topic:\(id1)", "kind")
        check(made.folder == "/tmp/verifier" && made.archived == false, "folder")
        let data = TopicAgents.encode([made])
        check(TopicAgents.decode(data) == [made], "round trip")
        let old = #"[{"id":"\#(id1)","name":"x","folder":"/f","created":"2026-01-01T00:00:00Z"}]"#
        check(TopicAgents.decode(Data(old.utf8)).first?.assistant == nil, "an old file still reads")
    }),
    ("tickets: the existing session is the newest of that assistant and ticket that is not archived", {
        let older = session(id1, created: 10), newer = session(id2, created: 20), archived = session(id3, created: 30, archived: true)
        let other = session("44444444-4444-4444-4444-444444444444", developer, created: 40)
        let topics = [older, newer, archived, other]
        check(TicketSessions.existing(assistant: verifier.key, subject: .ticket("ACME-1"), in: topics)?.id == id2, "newest")
        check(TicketSessions.existing(assistant: verifier.key, subject: .ticket("acme-1"), in: topics)?.id == id2, "case")
        check(TicketSessions.existing(assistant: verifier.key, subject: .ticket("ACME-2"), in: topics) == nil, "other ticket")
        check(TicketSessions.existing(assistant: developer.key, subject: .ticket("ACME-1"), in: topics)?.id == other.id, "other assistant")
        check(TicketSessions.sessions(subject: .ticket("ACME-1"), in: topics).map(\.id) == [other.id, id2, id1], "all of the ticket, newest first")
    }),
    ("tickets: the ticket's own agent is never taken for an assistant's session, and the other way round", {
        let own = TopicAgent(id: id1, name: "ACME-1 \u{00B7} Export", jiraKey: "ACME-1", folder: "/f", created: now)
        let sessions = [session(id2, created: 5), own]
        check(TopicAgents.existing(jiraKey: "ACME-1", in: sessions)?.id == id1, "existing")
        guard case .success(let target) = TopicAgents.resolve("ACME-1", topics: sessions) else { return check(false, "resolve") }
        check(target.key == own.key, target.key)
        check(TopicAgents.existing(jiraKey: "ACME-1", in: [session(id2)]) == nil, "only a session")
    }),
    ("tickets: with a session there, the user is asked unless the setting, the shortcut or the caller says otherwise", {
        let existing = session(id1)
        check(TicketSessions.resolve(existing: nil, forceNew: false, policy: .ask, alwaysReuse: false) == .create, "none: no question")
        check(TicketSessions.resolve(existing: nil, forceNew: false, policy: .reuse, alwaysReuse: true) == .create, "none, even when reusing")
        check(TicketSessions.resolve(existing: existing, forceNew: false, policy: .ask, alwaysReuse: false) == .ask(existing), "ask")
        check(TicketSessions.resolve(existing: existing, forceNew: false, policy: .reuse, alwaysReuse: false) == .reuse(existing), "always reuse")
        check(TicketSessions.resolve(existing: existing, forceNew: false, policy: .new, alwaysReuse: false) == .create, "always new")
        check(TicketSessions.resolve(existing: existing, forceNew: false, policy: .ask, alwaysReuse: true) == .reuse(existing), "the assistant's shortcut")
        check(TicketSessions.resolve(existing: existing, forceNew: true, policy: .reuse, alwaysReuse: true) == .create, "new_session forces a new one")
    }),
    ("tickets: the setting defaults to ask, and the shortcut is kept per assistant", {
        let store = defaults()
        check(TicketSessions.policy(defaults: store) == .ask && TicketSessions.alwaysReuse(defaults: store).isEmpty, "defaults")
        store.set("reuse", forKey: TicketSessions.policyKey)
        check(TicketSessions.policy(defaults: store) == .reuse, "reuse")
        store.set("nonsense", forKey: TicketSessions.policyKey)
        check(TicketSessions.policy(defaults: store) == .ask, "unknown reads as ask")
        TicketSessions.setAlwaysReuse(verifier.key, defaults: store)
        TicketSessions.setAlwaysReuse(developer.key, defaults: store)
        TicketSessions.setAlwaysReuse(verifier.key, defaults: store)
        check(TicketSessions.alwaysReuse(defaults: store) == [verifier.key, developer.key], "per assistant, once each")
    }),
    ("tickets: the preview says what the session is, how it stands, how old it is and what it last said", {
        let topic = session(id1, created: -7200)
        var working = AgentState(key: topic.key, title: topic.name, status: .working, updatedAt: now.addingTimeInterval(-7200))
        working.lastResult = "Line one\n\nLine two\nLine three\nLine four"
        let preview = TicketSessions.preview(of: topic, state: working)
        check(preview.state == "running" && preview.excerpt == "Line one / Line two / Line three" && preview.title == topic.name, "\(preview)")
        check(preview.line(now: now).contains("2 h") && preview.line(now: now).hasPrefix(topic.name + " \u{00B7} running"), preview.line(now: now))
        var idle = state(topic.key, status: .idle)
        idle.lastPrompt = "Verify it"
        idle.loaded = false
        check(TicketSessions.preview(of: topic, state: idle).state == "saved" && TicketSessions.preview(of: topic, state: idle).excerpt == "Verify it", "saved, prompt")
        check(TicketSessions.preview(of: topic, state: nil).state == "saved" && TicketSessions.preview(of: topic, state: nil).excerpt.isEmpty, "unknown")
        check(TicketSessions.stateText(AgentState(key: "k", title: "t", status: .waiting)) == "waiting for you", "waiting")
        let long = String(repeating: "word ", count: 100)
        check(TicketSessions.clip(long).count == TicketSessions.excerptLimit && TicketSessions.clip(long).hasSuffix("\u{2026}"), "clipped")
    }),
    ("tickets: the question names the assistant and the ticket and shows the session's preview", {
        let preview = TicketSessions.Preview(key: "topic:\(id1)", title: "ACME-1 \u{00B7} Verifier", state: "idle", updated: now.addingTimeInterval(-3600), excerpt: "PASS on all")
        let ask = TicketAsk(id: id2, workspace: "work", assistant: verifier.key, assistantName: "Verifier", ticket: "ACME-1", pullRequest: nil, existing: preview,
                            text: "Verify ACME-1", created: now, deadline: now.addingTimeInterval(1800))
        check(ask.title == "A Verifier session for ACME-1 exists", ask.title)
        let body = ask.body(now: now)
        check(body.contains("idle") && body.contains("1 h") && body.contains("PASS on all") && body.hasSuffix("Reuse it or start a new one?"), body)
        check(!ask.expired(now: now) && ask.expired(now: now.addingTimeInterval(1800)), "bounded")
        check(TicketAsks.decode(TicketAsks.encode([ask])) == [ask], "kept across a restart")
        check(TicketAsks.live([ask], now: now.addingTimeInterval(3600)).isEmpty && TicketAsks.live([ask], now: now).count == 1, "an old one is dropped")
    }),
    ("tickets: each ticket has its own question, and a second send for the same one waits for the first", {
        let preview = TicketSessions.Preview(key: "k", title: "t", state: "idle", updated: nil, excerpt: "")
        func ask(_ id: String, _ ticket: String, _ assistant: AssistantEntry = verifier) -> TicketAsk {
            TicketAsk(id: id, workspace: "work", assistant: assistant.key, assistantName: assistant.role.name, ticket: ticket, pullRequest: nil, existing: preview,
                      text: "x", created: now, deadline: now.addingTimeInterval(60))
        }
        let asks = [ask(id1, "ACME-1"), ask(id2, "ACME-2")]
        check(TicketAsks.pending(assistant: verifier.key, subject: .ticket("acme-1"), in: asks)?.id == id1, "ticket one")
        check(TicketAsks.pending(assistant: verifier.key, subject: .ticket("ACME-2"), in: asks)?.id == id2, "ticket two")
        check(TicketAsks.pending(assistant: verifier.key, subject: .ticket("ACME-3"), in: asks) == nil, "no question for a third")
        check(TicketAsks.pending(assistant: developer.key, subject: .ticket("ACME-1"), in: asks) == nil, "another assistant's session is another question")
        check(TicketAsks.identifier(id1) == "agent-ticket-ask:\(id1)", "identifier")
    }),
    ("tickets: the wait for an answer is bounded and the words say what happened", {
        check(RoleTools.waitSeconds(defaults: defaults()) == 30 * 60, "thirty minutes by default")
        let timeout = TicketSessions.timeoutMessage(role: "Verifier", subject: "ACME-1", minutes: 30)
        check(timeout.contains("30 minutes") && timeout.contains("Nothing was sent"), timeout)
        check(TicketSessions.timeoutMessage(role: "V", subject: "A-1", minutes: 1).contains("1 minute "), "singular")
        check(TicketSessions.chosenNote(.reuse, name: "n").contains("reuse"), "reuse")
        check(TicketSessions.chosenNote(.alwaysReuse, name: "n").contains("from now on"), "always")
        check(TicketSessions.chosenNote(.startNew, name: "n").contains("earlier one kept"), "new")
        check(TicketSessions.createdNote(name: "n").hasPrefix("Created") && TicketSessions.reusedNote(name: "n", preview: nil, now: now).hasPrefix("Reused"), "created, reused")
        check(TicketSessions.mainNote.contains("waiting for your answer on <KEY>") && TicketSessions.mainNote.contains("new_session"), "Main is told")
        check(AgentLogic.mainBasePrompt.contains(TicketSessions.mainNote), "in Main's prompt")
    }),
    ("tickets: an assistant's session works as the assistant for the ticket", {
        let text = TicketSessions.systemPrompt(base: "You are the Verifier.", subject: .ticket("ACME-1"))
        check(text.hasPrefix("You are the Verifier.") && text.contains("ACME-1") && text.contains("send_to_main"), text)
    }),
    ("slots: sessions beyond the limit, or beyond the assistant's own, wait", {
        check(SessionSlots.hasRoom(role: "a", roleLimit: nil, running: ["a", "b"], limit: 3), "room")
        check(!SessionSlots.hasRoom(role: "a", roleLimit: nil, running: ["a", "b", "c"], limit: 3), "full")
        check(SessionSlots.hasRoom(role: "a", roleLimit: nil, running: Array(repeating: "a", count: 20), limit: 0), "no limit")
        check(!SessionSlots.hasRoom(role: "a", roleLimit: 1, running: ["a"], limit: 0), "the assistant's own limit")
        check(SessionSlots.hasRoom(role: "a", roleLimit: 1, running: ["b", "b"], limit: 0), "another assistant's sessions do not count")
        check(SessionSlots.limit(defaults: defaults()) == 3, "default three")
        let store = defaults()
        store.set(0, forKey: TicketSessions.limitKey)
        check(SessionSlots.limit(defaults: store) == 0, "zero is no limit")
        store.set(-4, forKey: TicketSessions.limitKey)
        check(SessionSlots.limit(defaults: store) == 0, "never negative")
    }),
    ("slots: waiting sessions start oldest first, each taking a slot", {
        let waiting = [(id: "0", role: "v", roleLimit: Int?.none), (id: "1", role: "v", roleLimit: Int?.none), (id: "2", role: "d", roleLimit: Int?.none)]
        check(SessionSlots.startable(waiting: waiting, running: ["x", "y"], limit: 3) == ["0"], "one slot, the oldest")
        check(SessionSlots.startable(waiting: waiting, running: [], limit: 3) == ["0", "1", "2"], "all fit")
        check(SessionSlots.startable(waiting: waiting, running: ["x"], limit: 3) == ["0", "1"], "two fit")
        check(SessionSlots.startable(waiting: waiting, running: [], limit: 0) == ["0", "1", "2"], "no limit")
        let limited = [(id: "0", role: "v", roleLimit: Int?.some(1)), (id: "1", role: "v", roleLimit: Int?.some(1)), (id: "2", role: "d", roleLimit: Int?.none)]
        check(SessionSlots.startable(waiting: limited, running: [], limit: 0) == ["0", "2"], "one of each when the assistant allows one")
        check(TicketSessions.slotNote(limit: 3, roleLimit: 1).contains("at most 3") && TicketSessions.slotNote(limit: 3, roleLimit: 1).contains("at most 1"), "note")
    }),
    ("slots: an assistant's file can ask for fewer sessions at once", {
        let made = AssistantRole(slug: "verifier", name: "Verifier", summary: "Checks.", concurrency: 2, body: "Go.")
        let text = Assistants.serialise(made)
        check(text.contains("\nconcurrency: 2\n"), text)
        check(Assistants.parse(slug: "verifier", text: text) == made, "round trip")
        let plain = AssistantRole(slug: "p", name: "P", summary: "x", body: "")
        check(!Assistants.serialise(plain).contains("concurrency"), "not written when unset")
        let bad = Assistants.parse(slug: "v", text: text.replacingOccurrences(of: "concurrency: 2", with: "concurrency: 40"))
        check(bad.problems.first?.text.contains("1 to 10") == true && bad.concurrency == nil, "\(bad.problems)")
        let word = Assistants.parse(slug: "v", text: text.replacingOccurrences(of: "concurrency: 2", with: "concurrency: many"))
        check(!word.isUsable, "a word is no number")
    }),
    ("grouping: a ticket's sessions gather under one row at the place of the first", {
        let projects: Set<String> = ["ACME"]
        let verifier1 = state("topic:\(id1)", title: "ACME-1 \u{00B7} Verifier", ticket: "ACME-1", roleKey: verifier.key, role: "Verifier")
        let other = state("https://github.com/acme/web/pull/9", title: "acme/web#9 ACME-7: Something else", pr: "https://github.com/acme/web/pull/9")
        let developer1 = state("topic:\(id2)", title: "ACME-1 \u{00B7} Developer", ticket: "ACME-1", roleKey: developer.key, role: "Developer")
        let pull = state("https://github.com/acme/web/pull/3", title: "acme/web#3 ACME-1: Fix it", pr: "https://github.com/acme/web/pull/3")
        let rows = TicketGrouping.rows([verifier1, other, developer1, pull], projects: projects)
        check(rows.count == 2, "\(rows)")
        guard case .group(let group) = rows[0] else { return check(false, "first is the ticket") }
        check(group.ticket == "ACME-1" && group.members.map(\.key) == [verifier1.key, developer1.key, pull.key] && group.id == "ticket:ACME-1", "\(group)")
        check(group.rows.map(\.key) == [verifier1.key, developer1.key] && group.chips.map(\.url) == [pull.prURL!], "the pull request is a chip, the sessions are rows")
        guard case .agent(let lone) = rows[1] else { return check(false, "second is the lone pull request") }
        check(lone.key == other.key, "a lone pull request's agent stays as it is")
        check(TicketGrouping.label(verifier1) == "Verifier" && TicketGrouping.label(pull) == "web#3", "labels: \(TicketGrouping.label(pull))")
    }),
    ("grouping: two agents about a ticket make a row, one does not, and a pull request needs a project to name a ticket", {
        let a = state("topic:\(id1)", title: "ACME-5 \u{00B7} Export", ticket: "ACME-5")
        let b = state("https://github.com/acme/web/pull/3", title: "acme/web#3 ACME-5: Export", pr: "https://github.com/acme/web/pull/3")
        check(TicketGrouping.rows([a], projects: ["ACME"]).count == 1 && TicketGrouping.rows([a], projects: ["ACME"]).allSatisfy { if case .agent = $0 { true } else { false } }, "one agent")
        check(TicketGrouping.rows([a, b], projects: ["ACME"]).count == 1, "two make a row")
        check(TicketGrouping.rows([a, b], projects: []).count == 2, "no projects: the pull request names no ticket")
        check(TicketGrouping.ticket(of: b, projects: ["ACME"]) == "ACME-5" && TicketGrouping.ticket(of: b, projects: ["OTHER"]) == nil, "project")
        var group = TicketGroup(subject: .ticket("ACME-5"), members: [a, state("topic:\(id2)", status: .waiting, updated: 100)])
        check(group.needing == 1 && group.need == .waiting && group.latest == now.addingTimeInterval(100), "urgency bubbles up")
        group.members[1].status = .working
        check(group.need == .working && group.working == 1, "working")
    }),
    ("pull requests: a session for a pull request that names no ticket is kept by assistant and address", {
        let url = "https://github.com/acme-com/orbit.api/pull/12"
        let made = TicketSessions.make(entry: verifier, subject: .pullRequest(url), folder: "/tmp/v", id: id1, now: now)
        check(made.jiraKey == nil && made.pullRequestURL == url && made.assistant == verifier.key && made.name == "orbit.api#12 \u{00B7} Verifier", "\(made)")
        check(made.subject == .pullRequest(url) && session(id2).subject == .ticket("ACME-1"), "subjects")
        check(TopicAgent(id: id3, name: "x", folder: "/f", created: now).subject == nil, "an agent of its own has none")
        let topics = [made, session(id2, created: 50)]
        check(TicketSessions.existing(assistant: verifier.key, subject: .pullRequest(url), in: topics)?.id == id1, "found by address")
        check(TicketSessions.existing(assistant: developer.key, subject: .pullRequest(url), in: topics) == nil, "by assistant")
        check(TicketSessions.existing(assistant: verifier.key, subject: .pullRequest(url + "3"), in: topics) == nil, "another pull request")
        check(TicketSessions.existing(assistant: verifier.key, subject: .ticket("ACME-1"), in: topics)?.id == id2, "a ticket's is not a pull request's")
        check(TopicAgents.decode(TopicAgents.encode([made])) == [made], "round trip")
        check(TicketSessions.systemNote(subject: .pullRequest(url)).contains(url) && TicketSessions.systemNote(subject: .pullRequest(url)).contains("names no ticket"), "told")
        check(TicketSessions.name(subject: .pullRequest(url), role: "V") == "orbit.api#12 \u{00B7} V", "name")
    }),
    ("pull requests: the address is canonical, a ticket in the title wins and a closed session is not reused", {
        check(TicketSessions.pullRequest("https://github.com/acme-com/orbit.api/pull/12/files") == .success("https://github.com/acme-com/orbit.api/pull/12"), "canonical")
        guard case .failure(let bad) = TicketSessions.pullRequest("nope") else { return check(false, "bad") }
        check(bad.message.contains("nope"), bad.message)
        check(TicketSessions.pullRequest(nil) == .success(nil) && TicketSessions.pullRequest("  ") == .success(nil), "none")
        check(TicketSessions.ticket(inTitle: "ACME-7: Export", projects: ["acme"]) == "ACME-7", "title names it")
        check(TicketSessions.ticket(inTitle: "Export", projects: ["ACME"]) == nil && TicketSessions.ticket(inTitle: "ACME-7: x", projects: []) == nil && TicketSessions.ticket(inTitle: nil, projects: ["ACME"]) == nil, "none")
        let url = "https://github.com/acme-com/orbit.api/pull/12"
        var closed = TicketSessions.make(entry: verifier, subject: .pullRequest(url), folder: "/f", id: id1, now: now)
        closed.archived = true
        check(TicketSessions.existing(assistant: verifier.key, subject: .pullRequest(url), in: [closed]) == nil, "not reused")
        check(TicketSessions.sessions(subject: .pullRequest(url), in: [closed]).isEmpty && TicketSessions.sessions(subject: .pullRequest(url), in: [closed], archived: true).count == 1, "kept")
        check(SessionSubject(key: SessionSubject.pullRequest(url).key) == .pullRequest(url) && SessionSubject(key: "ticket:ACME-1") == .ticket("ACME-1"), "keys")
        check(SessionSubject(key: "pr:nope") == nil && SessionSubject(key: "topic:x") == nil && SessionSubject(key: "ticket:") == nil, "not keys")
    }),
    ("pull requests: a request names an assistant and a pull request, and the question is per pull request", {
        let url = "https://github.com/acme-com/orbit.api/pull/12"
        func request(_ agent: String, pr: String?, prs: [String]? = nil) -> AgentInbox.Request {
            AgentInbox.Request(id: id1, agent: agent, text: "Review", created: now, prs: prs, ticket: nil, newSession: nil, pr: pr, origin: "Review requested")
        }
        check(AgentInbox.problem(request(verifier.key, pr: url), now: now) == nil, "an assistant and a pull request")
        check(AgentInbox.problem(request("topic:\(id2)", pr: url), now: now) != nil, "not for a topic")
        check(AgentInbox.problem(request(verifier.key, pr: url + "/files"), now: now) != nil, "the address must be canonical")
        check(AgentInbox.problem(request(verifier.key, pr: url, prs: [url, url + "3"]), now: now) != nil, "not with a set")
        let preview = TicketSessions.Preview(key: "k", title: "t", state: "idle", updated: nil, excerpt: "")
        let ask = TicketAsk(id: id1, workspace: "work", assistant: verifier.key, assistantName: "Verifier", ticket: nil, pullRequest: url, existing: preview, text: "x",
                            created: now, deadline: now.addingTimeInterval(60), origin: "Review requested")
        check(ask.subject == .pullRequest(url) && ask.title == "A Verifier session for orbit.api#12 exists", ask.title)
        check(TicketAsks.pending(assistant: verifier.key, subject: .pullRequest(url), in: [ask]) != nil, "pending")
        check(TicketAsks.pending(assistant: verifier.key, subject: .ticket("ACME-1"), in: [ask]) == nil, "not a ticket's")
        check(TicketAsks.decode(TicketAsks.encode([ask])) == [ask], "kept")
    }),
    ("pull requests: grouping puts a pull request's sessions in a row, a ticket-naming pull request under its ticket, and closed ones under Earlier", {
        let url = "https://github.com/acme-com/orbit.api/pull/12"
        let named = "https://github.com/acme-com/orbit.api/pull/13"
        var session1 = state("topic:\(id1)", title: "orbit.api#12 \u{00B7} Verifier", roleKey: verifier.key, role: "Verifier")
        session1.sessionPR = url
        var closed = state("topic:\(id2)", title: "orbit.api#12 \u{00B7} Reviewer", roleKey: developer.key, role: "Reviewer")
        closed.sessionPR = url
        closed.archived = true
        let agent = state(url, title: "orbit.api#12 Add export", pr: url)
        var namedSession = state("topic:\(id3)", title: "orbit.api#13 \u{00B7} Verifier", roleKey: verifier.key, role: "Verifier")
        namedSession.sessionPR = named
        let lone = state("https://github.com/acme-com/orbit.api/pull/99", title: "orbit.api#99 Other", pr: "https://github.com/acme-com/orbit.api/pull/99")
        let rows = TicketGrouping.rows([session1, closed, agent, namedSession, lone], projects: ["ACME"], titles: [named: "ACME-5: Export it"])
        check(rows.count == 3, "\(rows.map(\.id))")
        guard case .group(let pullGroup) = rows[0], case .group(let ticketGroup) = rows[1], case .agent(let single) = rows[2] else { return check(false, "\(rows)") }
        check(pullGroup.subject == .pullRequest(url) && pullGroup.id == "pr:\(url)", "the pull request's row")
        check(pullGroup.rows.map(\.key) == [session1.key, agent.key] && pullGroup.earlier.map(\.key) == [closed.key] && pullGroup.live.count == 2, "live and earlier")
        check(pullGroup.chips.isEmpty, "a pull request's row has no chips")
        check(ticketGroup.subject == .ticket("ACME-5") && ticketGroup.chips.map(\.url) == [named] && ticketGroup.rows.isEmpty, "the ticket's row holds the pull request as a chip")
        check(single.key == lone.key, "a lone pull request's agent stays")
        check(pullGroup.need == .idle && pullGroup.id != ticketGroup.id, "ids")
        let onlyClosed = TicketGrouping.rows([closed], projects: [], titles: [:])
        check(onlyClosed.count == 1, "a closed session only shows inside a row: \(onlyClosed)")
        guard case .group(let alone)? = onlyClosed.first else { return check(false, "row") }
        check(alone.live.isEmpty && alone.earlier.count == 1 && alone.need == .idle, "kept")
        check(TicketGrouping.group("pr:\(url)", in: [session1, closed], projects: [], titles: [:])?.members.count == 2, "a group by its id")
        check(TicketGrouping.group("ticket:NONE-1", in: [session1], projects: [], titles: [:]) == nil, "none")
    }),
    ("pull requests: closed sessions are left out of the overview, the counts and the filters", {
        var closed = state("topic:\(id1)", title: "Closed", roleKey: verifier.key, role: "Verifier")
        closed.archived = true
        let open = state("topic:\(id2)", title: "Open", ticket: "ACME-1")
        check(AgentListFilter.counts([closed, open])[.all] == 1, "counted")
        let file = AgentOverview.File(written: now, agents: [closed, open])
        let text = AgentOverview.markdown(file, now: now)
        check(text.contains("Open") && !text.contains("Closed"), text)
        check(AgentFilter().matches(closed) == false && AgentFilter().matches(open), "filtered")
        var session = AgentState.topic(TicketSessions.make(entry: verifier, subject: .pullRequest("https://github.com/acme-com/orbit.api/pull/12"), folder: "/f", id: id3, now: now),
                                       loaded: nil, sessionID: nil, roleName: "Verifier")
        check(session.sessionPR == "https://github.com/acme-com/orbit.api/pull/12" && session.jiraKey == nil, "a pull request's session")
        check(AgentOverview.line(session, now: now).contains("Verifier session for the pull request"), AgentOverview.line(session, now: now))
        session.archived = true
        check(AgentOverview.markdown(AgentOverview.File(written: now, agents: [session]), now: now).hasPrefix("No agents yet."), "nothing to say")
    }),
    ("overview: ticket sessions are listed with their ticket and role and found by the ticket", {
        let topic = session(id1)
        var listed = AgentState.topic(topic, loaded: nil, sessionID: nil, roleName: "Verifier")
        listed.workspace = "work"
        check(listed.roleKey == verifier.key && listed.role == "Verifier" && listed.kind == "ticket_session" && listed.jiraKey == "ACME-1", "\(listed)")
        let line = AgentOverview.line(listed, now: now)
        check(line.contains("Verifier session for the ticket") && line.contains("Jira ACME-1"), line)
        listed.slotWait = true
        check(AgentOverview.line(listed, now: now).contains("waiting for a free slot"), "slot")
        check(AgentFilter.kind(of: listed) == "ticket_session", "kind")
        let pull = state("https://github.com/acme/web/pull/3", title: "acme/web#3 ACME-1: Fix", pr: "https://github.com/acme/web/pull/3")
        let unrelated = state("topic:\(id3)", title: "Other", ticket: "ACME-2")
        guard let filter = try? AgentFilter(["ticket": "acme-1"]) else { return check(false, "filter") }
        check(filter.ticket == "ACME-1" && filter.matches(listed) && filter.matches(pull) && !filter.matches(unrelated), "matches")
        check(filter.applied.contains { $0.contains("ACME-1") }, "applied: \(filter.applied)")
        check((try? AgentFilter(["ticket": "nope"])) == nil, "a bad key is an error")
        check((try? AgentFilter(["kind": "ticket_session"]))?.matches(listed) == true && (try? AgentFilter(["kind": "ticket"]))?.matches(listed) == false, "kinds")
        check(AgentFilter.properties["ticket"] != nil, "advertised")
    }),
    ("overview: a ticket session belongs to its assistant's workspace", {
        let file = WorkspaceFile(workspaces: Workspaces.sample)
        var listed = state("topic:\(id1)", title: "ACME-1", ticket: "ACME-1", roleKey: Assistants.key(workspace: "personal", slug: "verifier"))
        listed.folder = "/somewhere/else"
        check(Workspaces.assigned(listed, in: file, home: "/Users/x") == "personal", "by the assistant")
        listed.roleKey = Assistants.key(workspace: "gone", slug: "verifier")
        check(Workspaces.assigned(listed, in: file, home: "/Users/x") == Workspaces.workspace(nil, in: file.workspaces)?.id, "a workspace that is gone: the default")
    }),
    ("inbox: a ticket goes with an assistant, in its own form, and the reply tells what was done", {
        func request(_ agent: String, ticket: String?, prs: [String]? = nil) -> AgentInbox.Request {
            AgentInbox.Request(id: id1, agent: agent, text: "Verify", created: now, prs: prs, ticket: ticket, newSession: nil)
        }
        check(AgentInbox.problem(request(verifier.key, ticket: "ACME-1"), now: now) == nil, "an assistant and a ticket")
        check(AgentInbox.problem(request(verifier.key, ticket: nil), now: now) == nil, "no ticket is as before")
        check(AgentInbox.problem(request("topic:\(id2)", ticket: "ACME-1"), now: now)?.message.contains("assistant") == true, "not for a topic")
        check(AgentInbox.problem(request(verifier.key, ticket: "acme-1"), now: now) != nil, "the key must be normalised")
        check(AgentInbox.problem(request(verifier.key, ticket: "nope"), now: now) != nil, "a key")
        switch AgentInbox.request(agent: verifier.key, text: "x", now: now, id: id1, ticket: "ACME-1", newSession: true) {
        case .success(let made): check(made.ticket == "ACME-1" && made.newSession == true, "built")
        case .failure(let error): check(false, error.message)
        }
        let reply = AgentInbox.Reply(id: id1, status: .started, sessionID: nil, message: "started", note: "Created the session \u{201C}n\u{201D} for this ticket.")
        let text = AgentInbox.replyText(reply, title: "ACME-1 \u{00B7} Verifier")
        check(text.contains("working on it now") && text.contains("Created the session"), text)
        let rejected = AgentInbox.Reply(id: id1, status: .rejected, message: "Timed out", note: "ignored")
        check(!AgentInbox.replyText(rejected, title: "x").contains("ignored"), "no note on a refusal")
        check(AgentInbox.decode(AgentInbox.Reply.self, from: Data(#"{"id":"\#(id1)","status":"started","message":"m"}"#.utf8))?.note == nil, "an old reply reads")
    }),
    ("attention: the question's buttons are the notification's", {
        check(AgentAttention.response(action: AgentAttention.reuseAction, text: nil) == .reuse, "reuse")
        check(AgentAttention.response(action: AgentAttention.newSessionAction, text: nil) == .startNew, "new")
        check(AgentAttention.response(action: AgentAttention.alwaysReuseAction, text: nil) == .alwaysReuse, "always")
        check(AgentAttention.response(action: AgentAttention.openSessionAction, text: nil) == .open, "open")
        check(AgentAttention.ticketAskCategory == "agent-ticket-ask", "category")
    }),
    ("tickets: the report guidance asks for one line per ticket and Main collects them", {
        check(AgentReports.agentNote.contains("starts with the ticket key"), "agents")
        check(PromptBuiltIns.agentReport.contains("starts with the ticket key") && PromptBuiltIns.mainReportNote.contains("one table (ticket, outcome, link)"), "templates")
    }),
]
