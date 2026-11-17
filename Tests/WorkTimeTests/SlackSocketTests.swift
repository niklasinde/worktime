import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let me = SlackIdentity(userID: "UME", user: "niklas", teamID: "T1", team: "Acme", url: "https://acme.slack.com/")

private func frame(_ event: String, envelope: String = "e1") -> String {
    #"{"envelope_id":"\#(envelope)","type":"events_api","accepts_response_payload":false,"payload":{"team_id":"T1","event":\#(event)}}"#
}

private func pushed(_ text: String, channel: String = "C1", type: String? = "channel", user: String? = "UANNA", ts: String = "1800000000.000100",
                    thread: String? = nil) -> SlackSocketEvent {
    SlackSocketEvent(channel: channel, channelType: type, user: user, text: text, ts: ts, threadTS: thread)
}

private func automation(_ kind: AutomationTrigger.Kind, id: String = "A1", enabled: Bool = true) -> Routine {
    Routine(id: id, name: "Reviews", prompt: "p", workspace: "work", schedule: RoutineSchedule(kind: .daily), enabled: enabled, created: now,
            trigger: AutomationTrigger(kind: kind), followUp: AutomationFollowUp(notify: true, remind: false))
}

let slackSocketTests: [(name: String, run: () throws -> Void)] = [
    ("slack socket: frames are told apart, and only a message someone wrote becomes an event", {
        check(SlackSocketLogic.parse(#"{"type":"hello","num_connections":1}"#) == .hello, "hello")
        check(SlackSocketLogic.parse(#"{"type":"disconnect","reason":"refresh_requested"}"#) == .disconnect(reason: "refresh_requested"), "disconnect")
        let text = frame(#"{"type":"message","channel":"C1","channel_type":"channel","user":"UANNA","text":"review please","ts":"1800000000.000100"}"#)
        check(SlackSocketLogic.parse(text) == .message(envelope: "e1", event: pushed("review please")), "\(SlackSocketLogic.parse(text))")
        let reply = frame(#"{"type":"message","channel":"C1","channel_type":"group","user":"UANNA","text":"ok","ts":"1800000100.000100","thread_ts":"1800000000.000100"}"#)
        guard case .message(_, let event) = SlackSocketLogic.parse(reply) else { return check(false, "a reply is a message") }
        check(event.isReply && !event.isDirect && event.threadTS == "1800000000.000100", "\(event)")
        guard case .message(_, let direct) = SlackSocketLogic.parse(frame(#"{"type":"message","channel":"D1","channel_type":"im","user":"UANNA","text":"hi","ts":"1.1"}"#)) else {
            return check(false, "a direct message")
        }
        check(direct.isDirect && !direct.isReply, "\(direct)")
        for other in [#"{"type":"message","subtype":"message_changed","channel":"C1","ts":"1.1"}"#, #"{"type":"message","subtype":"channel_join","channel":"C1","user":"U1","ts":"1.1"}"#,
                      #"{"type":"message","bot_id":"B1","channel":"C1","text":"build","ts":"1.1"}"#, #"{"type":"reaction_added"}"#] {
            check(SlackSocketLogic.parse(frame(other)) == .other(envelope: "e1"), "ignored but answered: \(other)")
        }
        let broadcast = frame(#"{"type":"message","subtype":"thread_broadcast","channel":"C1","channel_type":"channel","user":"U2","text":"fyi","ts":"1.2","thread_ts":"1.1"}"#)
        guard case .message = SlackSocketLogic.parse(broadcast) else { return check(false, "a broadcast reply counts") }
        check(SlackSocketLogic.parse(#"{"type":"slash_commands","envelope_id":"e9"}"#) == .other(envelope: "e9"), "answered")
        check(SlackSocketLogic.parse("not json") == .other(envelope: nil), "garbage")
        check(SlackSocketLogic.isFromOthers(pushed("x"), me: me) && !SlackSocketLogic.isFromOthers(pushed("x", user: "UME"), me: me)
              && !SlackSocketLogic.isFromOthers(pushed("x", user: nil), me: me), "the user's own messages start nothing")
    }),

    ("slack socket: every envelope is answered with its id", {
        let data = Data(SlackSocketLogic.acknowledgement("abc-123").utf8)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        check(object == ["envelope_id": "abc-123"], "\(String(describing: object))")
    }),

    ("slack socket: retries wait longer up to a minute, and a quiet connection goes stale", {
        check((0...8).map(SlackSocketLogic.backoff) == [1, 2, 4, 8, 16, 32, 60, 60, 60], "\((0...8).map(SlackSocketLogic.backoff))")
        check(SlackSocketLogic.backoff(attempt: -3) == 1, "never negative")
        check(!SlackSocketLogic.stale(lastAlive: now, now: now.addingTimeInterval(60)) && SlackSocketLogic.stale(lastAlive: now, now: now.addingTimeInterval(81)), "stale")
    }),

    ("slack socket: the connection address comes from the app-level token, and a wrong token says so", {
        let request = SlackSocketLogic.openRequest(appToken: "xapp-1-A-1")
        check(request.url?.absoluteString == "https://slack.com/api/apps.connections.open" && request.httpMethod == "POST", "\(String(describing: request.url))")
        check(request.value(forHTTPHeaderField: "Authorization") == "Bearer xapp-1-A-1", "bearer")
        check(SlackSocketLogic.isAppToken("xapp-1-A-1") && !SlackSocketLogic.isAppToken("xoxp-1"), "app token")
        let url = try SlackSocketLogic.parseOpen(Data(#"{"ok":true,"url":"wss://wss-primary.slack.com/link/?ticket=t"}"#.utf8))
        check(url.absoluteString == "wss://wss-primary.slack.com/link/?ticket=t", "\(url)")
        for code in ["not_allowed_token_type", "invalid_auth", "missing_scope"] {
            do {
                _ = try SlackSocketLogic.parseOpen(Data(#"{"ok":false,"error":"\#(code)"}"#.utf8))
                check(false, "\(code) is refused")
            } catch let error as SlackError {
                check(error.message.contains("app-level token"), "\(code): \(error.message)")
            }
        }
        do {
            _ = try SlackSocketLogic.parseOpen(Data(#"{"ok":true,"url":"https://example.com"}"#.utf8))
            check(false, "only a websocket address")
        } catch {}
    }),

    ("slack socket: the manifest has Socket Mode, the message events and the sign-in's scopes, and nothing that writes", {
        let manifest = SlackSocketLogic.manifest()
        let root = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
        let settings = root?["settings"] as? [String: Any]
        check(settings?["socket_mode_enabled"] as? Bool == true, "socket mode")
        check((settings?["event_subscriptions"] as? [String: Any])?["user_events"] as? [String] == SlackSocketLogic.userEvents, "events")
        let oauth = root?["oauth_config"] as? [String: Any]
        check(((oauth?["scopes"] as? [String: Any])?["user"] as? [String])?.sorted() == SlackLogic.scopes.sorted(), "the scopes the sign-in asks for")
        check(oauth?["redirect_urls"] as? [String] == [SlackLogic.redirect], "redirect")
        check(!manifest.contains("write") && !manifest.contains("chat:") && !manifest.contains("\"bot\""), "nothing that posts")
        check(!manifest.contains("\\/"), "slashes are not escaped, so it pastes as it reads")
        check(SlackSocketLogic.steps.count == 5 && SlackSocketLogic.steps.contains { $0.contains("connections:write") }, "steps")
    }),

    ("slack socket: a pushed message makes the events the wanted triggers need, with the ids the search gives", {
        let message = Automations.socketMessage(pushed("please review https://github.com/acme-com/orbit.api/pull/7"), place: "#reviews", author: "Anna", me: me)
        let all: Set<AutomationTrigger.Kind> = [.slackChannel, .slackKeyword, .slackReply, .slackMessage]
        let events = Automations.socketEvents(message, event: pushed("please review https://github.com/acme-com/orbit.api/pull/7"), kinds: all, me: me, inMyThread: false)
        check(Set(events.map(\.kind)) == [.slackChannel, .slackKeyword], "a plain channel message: \(events.map(\.kind))")
        let channel = events.first { $0.kind == .slackChannel }?.event
        check(channel?.id == "slack_channel:C1-1800000000.000100" && channel?.place == "#reviews" && channel?.fields["slack_author"] == "Anna", "\(String(describing: channel))")
        check(channel?.pullRequest == "https://github.com/acme-com/orbit.api/pull/7" && channel?.link == "https://acme.slack.com/archives/C1/p1800000000000100", "\(String(describing: channel))")
        let search = SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: "#reviews", author: "Anna", text: "x", ts: "1800000000.000100", permalink: nil, unread: nil)
        check(Automations.slackEvent(search, link: nil, kind: .slackChannel).id == channel?.id, "the same id as a search result, so a message both ways runs once")

        let mention = pushed("<@UME> can you look?", ts: "1800000300.000100")
        let mentioned = Automations.socketEvents(Automations.socketMessage(mention, place: "#dev", author: "Anna", me: me), event: mention, kinds: [.slackMessage], me: me, inMyThread: false)
        check(mentioned.map(\.event.id) == ["slack:C1-1800000300.000100"], "\(mentioned.map(\.event.id))")
        let direct = pushed("got a minute?", channel: "D1", type: "im", ts: "1800000400.000100")
        let dm = Automations.socketEvents(Automations.socketMessage(direct, place: "Anna", author: "Anna", me: me), event: direct, kinds: [.slackMessage], me: me, inMyThread: false)
        check(dm.map(\.event.id) == ["slack:D1-1800000400.000100"] && dm.first?.event.place == "Anna", "\(dm.map(\.event.id))")

        let reply = pushed("ok?", ts: "1800000100.000100", thread: "1800000000.000100")
        let replyMessage = Automations.socketMessage(reply, place: "#dev", author: "Anna", me: me)
        check(Automations.socketEvents(replyMessage, event: reply, kinds: [.slackReply], me: me, inMyThread: false).isEmpty, "a thread the user did not write in")
        let replies = Automations.socketEvents(replyMessage, event: reply, kinds: [.slackReply], me: me, inMyThread: true)
        check(replies.map(\.event.id) == ["slack_reply:C1-1800000100.000100"], "\(replies.map(\.event.id))")
        check(Automations.socketEvents(message, event: pushed("top"), kinds: [.slackReply], me: me, inMyThread: true).isEmpty, "a message that is no reply")
        check(Automations.socketEvents(message, event: pushed("x"), kinds: [.reviewRequested, .jiraNew], me: me, inMyThread: true).isEmpty, "other kinds are not Slack's")
    }),

    ("slack socket: a message nothing waits for costs no lookup", {
        let reply = pushed("ok", ts: "1800000100.000100", thread: "1800000000.000100")
        check(!Automations.socketUseful(pushed("x"), kinds: []) && !Automations.socketUseful(pushed("x"), kinds: [.slackReply]), "no use")
        check(Automations.socketUseful(reply, kinds: [.slackReply]) && Automations.socketUseful(pushed("x"), kinds: [.slackReply, .slackChannel]), "use")
    }),

    ("slack socket: where a message was written reads like the search's places", {
        func place(_ type: String?, name: String?, author: String? = "Anna") -> String {
            Automations.socketPlace(pushed("x", type: type), conversation: name, author: author)
        }
        check(place("channel", name: "reviews") == "#reviews" && place("group", name: "secret") == "#secret", "channels")
        check(place("channel", name: nil) == "#C1", "an unknown name falls back to the id")
        check(place("im", name: nil) == "Anna" && place("im", name: nil, author: nil) == "Direct message", "direct")
        check(place("mpim", name: "mpdm-anna--bo--niklas-1") == "anna, bo, niklas" && place("mpim", name: nil) == "Group message", "group")
    }),

    ("slack socket: a pushed event goes to the automations that have looked at what was there, and says when one has not", {
        let ready = automation(.slackChannel, id: "A"), fresh = automation(.slackChannel, id: "B"), off = automation(.slackChannel, id: "C", enabled: false)
        let other = automation(.reviewRequested, id: "D")
        let routines = [ready, fresh, off, other]
        let target = Automations.socketTargets(kind: .slackChannel, routines: routines, baselined: ["A", "C", "D"])
        check(target.hand == ["A"] && target.needsBaseline, "\(target)")
        let all = Automations.socketTargets(kind: .slackChannel, routines: [ready], baselined: ["A"])
        check(all.hand == ["A"] && !all.needsBaseline, "\(all)")
        check(Automations.socketTargets(kind: .slackKeyword, routines: routines, baselined: ["A"]) == (hand: [], needsBaseline: false), "none for another kind")
        check(Automations.pushedKinds(of: routines) == [.slackChannel], "only Slack kinds, and only the ones that are on")
        check(Automations.pushedKinds(of: [off, other]).isEmpty, "none on, no socket")
        check(Automations.pushedKinds(of: [automation(.slackMessage), automation(.slackReply, id: "R"), automation(.jiraNew, id: "J")]) == [.slackMessage, .slackReply], "kinds")
    }),

    ("slack socket: a message the socket and the search both bring runs once", {
        let routine = automation(.slackChannel)
        let first = Automations.plan(kind: .slackChannel, events: [], routines: [routine], state: AutomationState(), now: now)
        check(first.fire.isEmpty && first.state.baselined.contains("A1"), "the search looks first")
        let message = Automations.socketMessage(pushed("deploy done"), place: "#reviews", author: "Anna", me: me)
        let pushedEvent = Automations.socketEvents(message, event: pushed("deploy done"), kinds: [.slackChannel], me: me, inMyThread: false)[0].event
        let viaSocket = Automations.plan(kind: .slackChannel, events: [pushedEvent], routines: [routine], state: first.state, now: now)
        check(viaSocket.fire.count == 1, "the socket starts it")
        let search = SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: "#reviews", author: "Anna", text: "deploy done", ts: "1800000000.000100", permalink: nil, unread: nil)
        let viaSearch = Automations.plan(kind: .slackChannel, events: [Automations.slackEvent(search, link: nil, kind: .slackChannel)], routines: [routine],
                                         state: viaSocket.state, now: now.addingTimeInterval(300))
        check(viaSearch.fire.isEmpty, "the search five minutes later does not start it again")
    }),
]
