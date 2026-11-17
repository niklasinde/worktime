import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let vocabulary = InCallVocabulary(ticketPrefixes: ["ACME", "ISD", "QPB"],
                                          sites: ["ACME": "acme.atlassian.net", "ISD": "acme.atlassian.net"],
                                          repos: ["acme-com/orbit.api", "acme-com/orbit.admin-ui"], names: ["Globex", "Nebula"])

private func keys(_ text: String, repoContext: String? = nil) -> [String] {
    EntitySpotter.spot(text, vocabulary: vocabulary, repoContext: repoContext).map(\.id)
}

private func past(_ id: Int64, _ title: String, daysAgo: Double, attendees: [String] = [], series: String? = nil,
                  mentions: Set<String> = [], app: String? = nil) -> PastMeeting {
    PastMeeting(id: id, title: title, date: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86400), sourceApp: app,
                attendees: attendees, seriesID: series, mentions: mentions)
}

private func event(_ id: String, _ start: Double, _ end: Double, url: String? = nil, notes: String? = nil) -> CalendarEventInfo {
    CalendarEventInfo(id: id, title: id, start: Date(timeIntervalSince1970: start * 60), end: Date(timeIntervalSince1970: end * 60),
                      notes: notes, url: url)
}

let inCallTests: [(name: String, run: () throws -> Void)] = [
    ("written Jira keys are spotted in English and Swedish lines, and look-alikes are not", {
        check(keys("Can you look at ACME-9031 before the release?") == ["ticket:ACME-9031"], "\(keys("Can you look at ACME-9031"))")
        check(keys("Jag tittade på ISD-12:an igår och QPB-934.") == ["ticket:ISD-12", "ticket:QPB-934"], "swedish")
        check(keys("It is UTF-8 encoded and ISO-8601 dated, COVID-19 aside.").isEmpty, "\(keys("UTF-8 ISO-8601 COVID-19"))")
        check(keys("Unknown project ABC-77 still counts") == ["ticket:ABC-77"], "unknown prefix written with a dash")
        check(keys("https://acme.atlassian.net/browse/ACME-8178") == ["ticket:ACME-8178"], "browse link")
    }),

    ("spoken Jira keys: spaces, spelled letters, digits read in pairs and the site's name as Whisper hears it", {
        check(keys("ACME 9031 är klar") == ["ticket:ACME-9031"], "space")
        check(keys("det är A C M E 9031 vi pratar om") == ["ticket:ACME-9031"], "spelled letters")
        check(keys("the A-C-M-E 90 31 one") == ["ticket:ACME-9031"], "dashes and pairs")
        check(keys("akme 9031 är mergad") == ["ticket:ACME-9031"], "akme")
        check(keys("Acme nummer 9 0 3 1") == ["ticket:ACME-9031"], "acme with filler, digit by digit")
        check(keys("acme9031") == ["ticket:ACME-9031"], "glued")
        check(keys("ACME 9031 12 people").first == "ticket:ACME-9031", "a full number is not merged with the next")
        check(keys("we had 12 issues and 9031 users").isEmpty, "numbers alone are nothing")
    }),

    ("pull requests from links, repo#number, and PR said with the repository on the line or just before", {
        check(keys("see https://github.com/acme-com/orbit.api/pull/2688/files") == ["pr:acme-com/orbit.api#2688"], "link")
        check(keys("orbit.api#2688 is green").contains("pr:acme-com/orbit.api#2688"), "\(keys("orbit.api#2688 is green"))")
        check(keys("PR 2688 i orbit api behöver en review").contains("pr:acme-com/orbit.api#2688"),
              "\(keys("PR 2688 i orbit api behöver en review"))")
        check(keys("PR:en 26 88 är godkänd", repoContext: "acme-com/orbit.admin-ui") == ["pr:acme-com/orbit.admin-ui#2688"], "context")
        check(keys("the pull request 2688 failed") == ["pr:#2688"], "no repository yet")
        check(keys("#2688 failed").isEmpty, "a bare hash needs a repository")
        check(keys("orbit dot api, #2688 failed").contains("pr:acme-com/orbit.api#2688"), "\(keys("orbit dot api, #2688 failed"))")
    }),

    ("known names are spotted by their words, short ones are not", {
        check(keys("Globex vill ha exporten i orbit admin ui") == ["name:Globex", "name:orbit.admin-ui"],
              "\(keys("Globex vill ha exporten i orbit admin ui"))")
        check(keys("globexsomething").isEmpty, "whole words only")
    }),

    ("phonetic keys meet for Whisper's spellings of one name", {
        check(EntitySpotter.phonetic("Acme") == EntitySpotter.phonetic("akme"), "acme/akme")
        check(EntitySpotter.phonetic("Kwiddly") == EntitySpotter.phonetic("quidly"), "kwiddly/quidly")
        check(InCallVocabulary.spells("ACME", in: "acme") && !InCallVocabulary.spells("ISD", in: "acme"), "spells")
        check(vocabulary.aliases[EntitySpotter.phonetic("acme")] == "ACME", "\(vocabulary.aliases)")
    }),

    ("merging keeps one of each, and a pull request's repository replaces the bare number", {
        let bare = SpottedEntity.pullRequest(repo: nil, number: 2688)
        let full = SpottedEntity.pullRequest(repo: "acme-com/orbit.api", number: 2688)
        let ticket = SpottedEntity(kind: .ticket, key: "ACME-9031")
        var merged = InCallLogic.merge([], [ticket, bare])
        check(merged.added.map(\.id) == ["ticket:ACME-9031", "pr:#2688"], "first")
        merged = InCallLogic.merge(merged.all, [ticket, full])
        check(merged.added.map(\.id) == ["pr:acme-com/orbit.api#2688"] && merged.all.count == 2, "\(merged.all.map(\.id))")
        merged = InCallLogic.merge(merged.all, [bare])
        check(merged.added.isEmpty && merged.all.count == 2, "bare after full is dropped")
        check(InCallLogic.mentioned(merged.all + [SpottedEntity(kind: .name, key: "Globex")]) == "ACME-9031, orbit.api#2688", "mentioned")
    }),

    ("the repository talked about in the last two minutes is the context for a bare PR", {
        let entities = [SpottedEntity(kind: .name, key: "orbit.api", at: 10), SpottedEntity(kind: .ticket, key: "ACME-1", at: 50)]
        check(InCallLogic.repoContext(entities, at: 60, vocabulary: vocabulary) == "acme-com/orbit.api", "recent")
        check(InCallLogic.repoContext(entities, at: 200, vocabulary: vocabulary) == nil, "too old")
    }),

    ("questions about what was decided before, in English and Swedish", {
        for yes in ["What did we decide last time about the export?", "Where did we land on the API change?",
                    "Vad bestämde vi förra gången?", "vad kom vi fram till om Globex", "Vad sa vi senast om releasen?",
                    "remind me what we agreed"] {
            check(InCallLogic.asksAboutLastTime(yes), yes)
        }
        for no in ["What did we say?", "vad sa vi", "We decided to ship on Friday.", "Vad tycker du?"] {
            check(!InCallLogic.asksAboutLastTime(no), no)
        }
    }),

    ("Ministral runs at most once a minute, on mains power, while the live text keeps up", {
        let now = Date(timeIntervalSince1970: 1000)
        check(InCallLogic.shouldAskModel(now: now, last: nil, onBattery: false, pending: 0, newLines: 3, allowed: true), "first")
        check(!InCallLogic.shouldAskModel(now: now, last: now.addingTimeInterval(-30), onBattery: false, pending: 0, newLines: 3, allowed: true), "too soon")
        check(InCallLogic.shouldAskModel(now: now, last: now.addingTimeInterval(-61), onBattery: false, pending: 0, newLines: 3, allowed: true), "a minute on")
        check(!InCallLogic.shouldAskModel(now: now, last: nil, onBattery: true, pending: 0, newLines: 3, allowed: true), "battery")
        check(!InCallLogic.shouldAskModel(now: now, last: nil, onBattery: false, pending: 9, newLines: 3, allowed: true), "behind")
        check(!InCallLogic.shouldAskModel(now: now, last: nil, onBattery: false, pending: 0, newLines: 0, allowed: true), "nothing new")
        check(!InCallLogic.shouldAskModel(now: now, last: nil, onBattery: false, pending: 0, newLines: 3, allowed: false), "off")
    }),

    ("retrieval ranks the same recurring event, the same people and shared tickets over a similar title", {
        let context = RetrievalContext(entities: ["ticket:ACME-9031"], title: "Globex export sync", attendees: ["anna@globex.example", "bo@acme.com"],
                                       sourceApp: "Microsoft Teams", seriesID: "series-1", now: Date(timeIntervalSince1970: 1_800_000_000))
        let meetings = [
            past(1, "Lunch", daysAgo: 1),
            past(2, "Globex export", daysAgo: 20),
            past(3, "Weekly", daysAgo: 7, series: "series-1"),
            past(4, "Standup", daysAgo: 3, mentions: ["ticket:ACME-9031"]),
            past(5, "Kundmöte", daysAgo: 14, attendees: ["Anna@globex.example", "bo@acme.com"]),
        ]
        let ranked = InCallRetrieval.rank(meetings, context: context, limit: 5).map(\.id)
        check(ranked == [3, 5, 4, 2], "the last of the series, then the same people, then the shared ticket: \(ranked)")
        check(!ranked.contains(1), "recency alone is not enough")
        check(InCallRetrieval.words("Globex – exporten & möte") == ["globex", "exporten"], "\(InCallRetrieval.words("Globex – exporten & möte"))")
    }),

    ("the decision prompt numbers the meetings and the answer cites the one it came from", {
        var meeting = past(7, "Globex export", daysAgo: 7)
        meeting.decisions = ["Exporten går som CSV.", "Anna testar på fredag."]
        let prompt = InCallPrompts.decision(question: "Vad bestämde vi förra gången?", meetings: [meeting], language: "Swedish")
        check(prompt.prompt.contains("Meeting 1: Globex export (2027-01-08)") && prompt.prompt.contains("- Exporten går som CSV."), prompt.prompt)
        check(prompt.system.contains("Swedish"), "language")
        let answer = InCallPrompts.parseDecision(#"{"found": true, "answer": "CSV-export, Anna testar.", "meeting": 1}"#, meetings: [meeting])
        check(answer == InCallAnswer(text: "CSV-export, Anna testar.", meetingID: 7, meetingTitle: "Globex export", date: meeting.date), "\(String(describing: answer))")
        check(InCallPrompts.parseDecision(#"{"found": false, "answer": "", "meeting": 0}"#, meetings: [meeting]) == nil, "not found")
        check(InCallPrompts.parseDecision("no json", meetings: [meeting]) == nil, "garbage")
        check(InCallPrompts.fallback(meeting)?.text == "Exporten går som CSV. Anna testar på fredag.", "fallback")
        check(LocalLLMLogic.grammar(schema: InCallPrompts.decisionSchema).contains("root ::="), "schema has a grammar")
    }),

    ("Ministral's extraction is kept only where the spotter recognises it", {
        let reply = #"{"tickets": ["ACME-9031", "akme 12"], "pullRequests": ["orbit.api#2688"], "names": ["Globex", "Made Up Corp"], "asksWhatWasDecided": true}"#
        let parsed = InCallPrompts.parseExtraction(reply, at: 30, vocabulary: vocabulary)
        check(Set(parsed.entities.map(\.id)) == ["ticket:ACME-9031", "ticket:ACME-12", "pr:acme-com/orbit.api#2688", "name:orbit.api", "name:Globex"],
              "\(parsed.entities.map(\.id))")
        check(parsed.asks, "asks")
        check(InCallPrompts.extraction(lines: ["a"], vocabulary: vocabulary).prompt.contains("ACME-123"), "known prefixes listed")
    }),

    ("the calendar event running when the recording starts wins, then the one in the call's app", {
        let start = Date(timeIntervalSince1970: 600 * 60)
        let running = event("running", 590, 630)
        let soon = event("soon", 605, 640, url: "https://meet.google.com/abc-defg-hij")
        let ended = event("ended", 500, 560)
        check(CalendarLogic.pick([soon, running, ended], at: start, sourceApp: nil)?.id == "running", "running")
        let teams = event("teams", 590, 630, notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting")
        check(CalendarLogic.pick([running, teams], at: start, sourceApp: "Microsoft Teams")?.id == "teams", "tie-break by app")
        check(CalendarLogic.pick([soon, ended], at: start, sourceApp: nil)?.id == "soon", "about to start")
        check(CalendarLogic.pick([ended], at: start, sourceApp: nil) == nil, "long over")
        check(CalendarLogic.service(of: soon) == "Google Meet", "meet")
    }),

    ("an event's agenda drops HTML and joining instructions, and its tickets seed the spotter", {
        let notes = """
            <p>Agenda:</p><ul><li>Go through ACME-9031</li><li>PR orbit.api#2688</li></ul>
            ________________________________________________________________________________
            Microsoft Teams meeting
            Join on your computer, mobile app or room device
            https://teams.microsoft.com/l/meetup-join/19%3ameeting
            Meeting ID: 123 456 789
            Passcode: abc
            """
        check(CalendarLogic.agenda(notes) == "Agenda:\nGo through ACME-9031\nPR orbit.api#2688", "\(String(describing: CalendarLogic.agenda(notes)))")
        check(CalendarLogic.agenda("Meeting ID: 1") == nil, "nothing left")
        check(CalendarLogic.agenda(String(repeating: "word ", count: 100), limit: 20)?.count == 20, "cut")
        var info = event("Globex sync", 0, 30, notes: notes)
        info.attendees = [CalendarAttendee(name: "Anna", email: "Anna@globex.example")]
        check(CalendarLogic.seeds(info, vocabulary: vocabulary).map(\.id) == ["ticket:ACME-9031", "pr:acme-com/orbit.api#2688"],
              "\(CalendarLogic.seeds(info, vocabulary: vocabulary).map(\.id))")
        check(info.attendees[0].identity == "anna@globex.example", "identity")
        check(CalendarLogic.summaryContext(title: "Globex sync", attendees: ["Anna"], agenda: "A\nB")
              == ["[Calendar event: Globex sync]", "[Invited: Anna]", "[Agenda: A / B]"], "summary context")
        check(CalendarLogic.summaryContext(title: nil, attendees: ["Anna"], agenda: "A").isEmpty, "no event, no context")
    }),

    ("cards: the meeting's own card first, then newest first, without dismissed ones; updates keep their place", {
        let now = Date()
        var cards = [InCallCard(id: "t", kind: .ticket(.init(key: "ACME-1")), added: now),
                     InCallCard(id: "p", kind: .pullRequest(.init(repo: "a/b", number: 2)), added: now.addingTimeInterval(5)),
                     InCallCard(id: "about", kind: .about(event("x", 0, 1)), added: now.addingTimeInterval(-60))]
        check(InCallCard.order(cards, dismissed: []).map(\.id) == ["about", "p", "t"], "order")
        check(InCallCard.order(cards, dismissed: ["p"]).map(\.id) == ["about", "t"], "dismissed")
        InCallCard.upsert(InCallCard(id: "t", kind: .ticket(.init(key: "ACME-1", status: "Done")), added: now.addingTimeInterval(99)), into: &cards)
        check(cards.count == 3 && InCallCard.order(cards, dismissed: []).map(\.id) == ["about", "p", "t"], "update in place")
        check(InCallCard.PullRequest(repo: "acme-com/orbit.api", number: 2688).label == "orbit.api#2688", "label")
    }),

    ("mentions and the calendar event are stored with the meeting and feed the next call's retrieval", {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("incall-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try MeetingStore.open(at: folder.appendingPathComponent("meetings.sqlite"))
        let earlier = "Meeting-2026-11-04-1000.m4a", now = "Meeting-2026-11-11-1000.m4a"
        try store.beginRecording(earlier, created: Date(timeIntervalSince1970: 1_793_000_000), audioExpiresAt: nil)
        try store.beginRecording(now, created: Date(timeIntervalSince1970: 1_793_600_000), audioExpiresAt: nil)
        let heard = ["Vi måste titta på akme 90 31 innan fredag.", "PR 2688 i orbit api är grön."]
        var entities: [SpottedEntity] = []
        for (index, line) in heard.enumerated() {
            let context = InCallLogic.repoContext(entities, at: Double(index * 10), vocabulary: vocabulary)
            entities = InCallLogic.merge(entities, EntitySpotter.spot(line, at: Double(index * 10), vocabulary: vocabulary, repoContext: context)).all
        }
        try store.saveMentions(earlier, entities)
        try store.saveMentions(earlier, entities)
        check(try store.mentions(of: earlier).map(\.id) == ["ticket:ACME-9031", "pr:acme-com/orbit.api#2688", "name:orbit.api"],
              "\(try store.mentions(of: earlier).map(\.id))")
        let event = CalendarEventInfo(id: "e1", seriesID: "s1", title: "Globex sync", start: Date(timeIntervalSince1970: 1_793_000_000),
                                      end: Date(timeIntervalSince1970: 1_793_001_800), attendees: [CalendarAttendee(name: "Anna", email: "anna@globex.example")])
        try store.saveCalendarEvent(earlier, StoredMeetingEvent(event: event, agenda: "Export"))
        check(try store.calendarEvent(of: earlier) == StoredMeetingEvent(event: event, agenda: "Export"), "event round trip")
        check(try store.calendarEvent(of: now) == nil, "none for the other")
        try store.saveSummary(earlier, ParsedSummary(MeetingSummary(title: "Globex-exporten", actionItems: [.init(task: "Testa exporten", owner: "Anna")],
                                                                    topics: [.init(title: "Export", points: ["Exporten går som CSV."])]), engine: "test"))
        let candidates = try store.pastMeetings(excluding: now)
        check(candidates.map(\.id).count == 1 && candidates[0].seriesID == "s1" && candidates[0].attendees == ["anna@globex.example"]
              && candidates[0].mentions.contains("ticket:ACME-9031"), "\(candidates)")
        let context = RetrievalContext(entities: ["ticket:ACME-9031"], seriesID: "s1", now: Date(timeIntervalSince1970: 1_793_600_000))
        let best = try InCallRetrieval.rank(candidates, context: context).map(store.pastMeetingDetails)
        check(best.first?.decisions == ["Exporten går som CSV."] && best.first?.actionItems == ["Anna: Testa exporten"], "\(best)")
        let found = try store.meetings(mentioning: SpottedEntity(kind: .ticket, key: "ACME-9031"), excluding: now)
        check(found.map(\.line) == ["Vi måste titta på akme 90 31 innan fredag."], "\(found)")
        check(try store.meetings(mentioning: SpottedEntity(kind: .ticket, key: "ACME-9031"), excluding: earlier).isEmpty, "own meeting left out")
        try store.delete(earlier)
        check(try store.mentions(of: earlier).isEmpty, "deleted with the meeting")
    }),
]
