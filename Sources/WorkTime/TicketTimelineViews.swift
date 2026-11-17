import Combine
import SwiftUI

/// The events of a ticket's or pull request's sessions, read from the sessions as they are: the models of the ones that are open, and
/// the saved transcripts of the others, brought in the way a session is when it is opened. Each session is read a changed item at a time.
@MainActor
final class TimelineModel: ObservableObject {
    @Published private(set) var events: [TimelineEvent] = []
    private var scanners: [String: TimelineScanner] = [:]
    private var bound: [String: AnyCancellable] = [:]
    private var attaching: Set<String> = []
    private var posted: [TimelineEvent] = []

    func bind(_ group: TicketGroup) {
        let keys = Set(group.members.map(\.key))
        for key in bound.keys where !keys.contains(key) {
            bound[key] = nil
            scanners[key] = nil
        }
        for state in group.members where bound[state.key] == nil && attaching.insert(state.key).inserted { attach(state) }
        posted = Self.postedEvents(group)
        rebuild()
    }

    private func attach(_ state: AgentState) {
        Task { @MainActor in
            defer { attaching.remove(state.key) }
            guard let model = await Self.model(for: state) else { return }
            var scanner = TimelineScanner(session: state.key, label: TicketGrouping.label(state))
            scanner.update(model.items)
            scanners[state.key] = scanner
            rebuild()
            bound[state.key] = model.$items.debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] items in
                self?.scanners[state.key]?.update(items)
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        events = Timeline.merged(scanners.keys.sorted().map { scanners[$0]?.events ?? [] } + [posted])
    }

    /// The agent behind a row of the group: made and loaded when it is not yet, which reads its saved transcript.
    static func model(for state: AgentState) async -> AgentModel? {
        if TopicAgents.isKey(state.key) { return TopicAgentStore.shared.topic(state.key).map { TopicAgentStore.shared.load($0) } }
        if let target = GitHubLink.pullRequest(at: state.key) { return await PRAgents.shared.load(target) }
        return nil
    }

    /// The reviews and comments posted for the group's pull requests, from the app's log of GitHub actions.
    static func postedEvents(_ group: TicketGroup) -> [TimelineEvent] {
        var owners: [String: (key: String, label: String)] = [:]
        for state in group.members {
            guard let url = TicketGroup.pullRequest(of: state) else { continue }
            if owners[url] == nil || state.prURL != nil { owners[url] = (state.key, TicketGrouping.label(state)) }
        }
        return Timeline.posted((try? GitHubModel.shared.store?.githubActions(limit: 500)) ?? [], url: { "https://github.com/\($0.repo)/pull/\($0.number)" }, session: { owners[$0] })
    }
}

/// A ticket's or pull request's page on the Main page: its timeline across all its sessions, and the sessions themselves.
struct TicketTimelinePage: View {
    let id: String
    @Binding var listHidden: Bool
    @ObservedObject private var hub = AgentHub.shared
    @ObservedObject private var writer = AgentStateWriter.shared
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @ObservedObject private var directory = SessionRefDirectory.shared
    @StateObject private var model = TimelineModel()
    @State private var tab = Tab.timeline

    private enum Tab: String, CaseIterable, Identifiable {
        case timeline = "Timeline", sessions = "Sessions"
        var id: String { rawValue }
    }

    private var group: TicketGroup? {
        let projects = Set(workspaces.workspaces.flatMap(\.jiraProjects).map { $0.uppercased() })
        let titles = Dictionary(GitHubModel.shared.prs.values.joined().map { ($0.url, $0.title) }) { first, _ in first }
        return TicketGrouping.group(id, in: writer.states(), projects: projects, titles: titles)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let group {
                switch tab {
                case .timeline: TimelineList(events: model.events, hub: hub)
                case .sessions: sessions(group)
                }
            } else {
                Text("Nothing left for \(SessionSubject(key: id)?.label ?? "this"): its sessions were deleted.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, minHeight: 440)
        .task(id: group?.members.map(\.key) ?? []) { if let group { model.bind(group) } }
    }

    private var subject: SessionSubject? { SessionSubject(key: id) }

    private var header: some View {
        HStack(spacing: 10) {
            Button { listHidden.toggle() } label: { Image(systemName: "sidebar.squares.left") }
                .buttonStyle(.borderless)
                .help(listHidden ? "Show the agents" : "Hide the agents")
            if let subject {
                Label {
                    Text(subject.label).font(.system(size: 15, weight: .medium)).lineLimit(1)
                } icon: {
                    if subject.ticket != nil { BrandMark.jira.resizable().scaledToFit().frame(width: 12, height: 12) } else { Image(systemName: "arrow.triangle.pull") }
                }
                if let title = info(subject)?.title, !title.isEmpty { Text(title).foregroundStyle(.secondary).lineLimit(1) }
                if let status = info(subject)?.status, subject.ticket != nil { StatusChip(text: status, kind: info(subject)?.statusKind) }
            }
            Spacer()
            Picker("View", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, RecordingDetail.gutter)
        .padding(.vertical, 10)
    }

    private func info(_ subject: SessionSubject) -> SessionRefInfo? {
        switch subject {
        case .ticket(let key): directory.entries[SessionRef.jira(key).cacheKey]?.info
        case .pullRequest(let url): GitHubLink.pullRequest(at: url).flatMap { directory.entries[SessionRef($0).cacheKey]?.info }
        }
    }

    private func sessions(_ group: TicketGroup) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(group.live, id: \.key) { state in
                    Button { hub.selected = state.key } label: { TicketMemberRow(state: state, selected: false) }.buttonStyle(.plain)
                }
                if !group.earlier.isEmpty {
                    Text("Earlier").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 30).padding(.top, 10)
                    ForEach(group.earlier, id: \.key) { state in
                        Button { hub.selected = state.key } label: { TicketMemberRow(state: state, selected: false) }.buttonStyle(.plain).opacity(0.7)
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(RecordingDetail.gutter)
        }
    }
}

/// The events by day, oldest first, each opening the place in its session's transcript.
private struct TimelineList: View {
    let events: [TimelineEvent]
    let hub: AgentHub

    private var days: [(day: Date, events: [TimelineEvent])] {
        let calendar = Calendar.current
        return Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }.map { (day: $0.key, events: $0.value) }.sorted { $0.day < $1.day }
    }

    var body: some View {
        if events.isEmpty {
            Text("Nothing has happened in these sessions yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(days, id: \.day) { day in
                        Text(day.day.formatted(date: .complete, time: .omitted)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, 10).padding(.bottom, 2)
                        ForEach(day.events) { event in
                            Button { hub.jump(to: event.session, item: event.item) } label: { row(event) }
                                .buttonStyle(.plain)
                                .help(event.item == nil ? "Open the session" : "Open the session at this point")
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, RecordingDetail.gutter)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
        }
    }

    private func row(_ event: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(event.date.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing)
            Image(systemName: Self.symbol(event.kind)).font(.callout).foregroundStyle(Self.color(event.kind)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).lineLimit(2).multilineTextAlignment(.leading)
                if let detail = event.detail, !detail.isEmpty, event.kind != .reply || event.title.count < 60 {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 6)
            Text(event.sessionLabel).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07))).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    static func symbol(_ kind: TimelineEvent.Kind) -> String {
        switch kind {
        case .trigger: "bolt.fill"
        case .prompt: "arrow.right.circle"
        case .outcome: "checkmark.seal"
        case .review: "doc.text.magnifyingglass"
        case .posted: "paperplane.fill"
        case .feedback: "text.bubble"
        case .approval: "hand.raised"
        case .offer: "sparkles"
        case .reply: "bubble.left"
        }
    }

    static func color(_ kind: TimelineEvent.Kind) -> Color {
        switch kind {
        case .trigger: .orange
        case .prompt: .purple
        case .outcome: .green
        case .review: .blue
        case .posted: .accentColor
        case .feedback: .primary
        case .approval: .orange
        case .offer: .purple
        case .reply: .secondary
        }
    }
}
