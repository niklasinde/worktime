import Foundation

/// Names looked up for pushed messages, kept so a busy channel asks Slack once.
@MainActor
final class SlackSocketNames {
    private var users: [String: String] = [:]
    private var channels: [String: String] = [:]
    private var mine: [String: (writes: Bool, checked: Date)] = [:]
    private static let recheck: TimeInterval = 120

    func author(_ id: String?, client: SlackClient) async -> String? {
        guard let id else { return nil }
        if let known = users[id] { return known }
        guard let name = try? await client.userName(id) else { return id }
        users[id] = name
        return name
    }

    func conversation(_ id: String, client: SlackClient) async -> String? {
        if let known = channels[id] { return known }
        guard let name = (try? await client.conversation(id))?.name else { return nil }
        channels[id] = name
        return name
    }

    /// Whether the user wrote in the thread; a no is asked again after a while, as the user may join it.
    func writes(in event: SlackSocketEvent, me: SlackIdentity, client: SlackClient, now: Date = Date()) async -> Bool {
        guard let root = event.threadTS, event.isReply else { return false }
        let key = event.channel + root
        if let known = mine[key], known.writes || now.timeIntervalSince(known.checked) < Self.recheck { return known.writes }
        guard let host = URL(string: me.url)?.host else { return false }
        let link = SlackThreadLink(host: host, channel: event.channel, ts: root, threadTS: nil)
        let writes = (try? await client.thread(link))?.messages.contains { $0.user == me.userID } ?? false
        mine[key] = (writes, now)
        return writes
    }

    func noteOwn(_ event: SlackSocketEvent, now: Date = Date()) {
        guard let root = event.threadTS, event.isReply else { return }
        mine[event.channel + root] = (true, now)
    }
}

extension AutomationSources {
    func startSocket() {
        let socket = SlackSocket.shared
        socket.onEvent = { [weak self] event in Task { await self?.handle(event) } }
        socket.onConnected = { [weak self] in Task { await self?.poll() } }
        socket.onTokenChanged = { [weak self] in self?.updateSocket() }
        RoutineStore.shared.$routines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSocket() }
            .store(in: &socketSubscriptions)
        SlackModel.shared.$hasToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSocket() }
            .store(in: &socketSubscriptions)
        updateSocket()
    }

    /// Keeps the socket open only while an enabled Slack automation needs it and automations are on.
    func updateSocket() {
        let store = RoutineStore.shared
        let wanted = SlackModel.shared.hasToken && Automations.enabled && !Automations.pushedKinds(of: store.routines).isEmpty
        SlackSocket.shared.setWanted(wanted)
    }

    /// A message Slack pushed: its events go to the automations waiting for them, once their search has seen what was there.
    func handle(_ event: SlackSocketEvent) async {
        let store = RoutineStore.shared
        guard store.automationsEnabled() else { return }
        let kinds = Automations.pushedKinds(of: store.routines)
        guard Automations.socketUseful(event, kinds: kinds), let access = MCPServer.storedSlack() else { return }
        let names = socketNames
        let known = SlackModel.shared.identity
        let events: [(kind: AutomationTrigger.Kind, event: AutomationEvent)]
        do {
            events = try await access.run { client in
                let me: SlackIdentity
                if let known { me = known } else { me = try await client.identity() }
                guard SlackSocketLogic.isFromOthers(event, me: me) else {
                    if event.user == me.userID { names.noteOwn(event) }
                    return []
                }
                let author = await names.author(event.user, client: client)
                var conversation: String?
                if event.channelType != "im" { conversation = await names.conversation(event.channel, client: client) }
                let place = Automations.socketPlace(event, conversation: conversation, author: author)
                let message = Automations.socketMessage(event, place: place, author: author, me: me)
                let mine = kinds.contains(.slackReply) ? await names.writes(in: event, me: me, client: client) : false
                return Automations.socketEvents(message, event: event, kinds: kinds, me: me, inMyThread: mine)
            }
        } catch { return }
        var baseline = false
        for (kind, automation) in events {
            let targets = Automations.socketTargets(kind: kind, routines: store.routines, baselined: store.baselinedAutomations)
            for id in targets.hand { store.ingest(kind: kind, events: [automation], only: id) }
            baseline = baseline || (targets.needsBaseline && kind.polled)
        }
        if baseline { await poll() }
    }
}
