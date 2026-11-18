import AppKit
import Combine
import SwiftUI
import Foundation

/// Follows where the main window is and walks back and forth through it. Each page keeps its own selection; this reads them
/// and puts them back.
@MainActor
final class NavigationModel: ObservableObject {
    @Published private(set) var history = NavigationHistory()
    private let library: RecordingLibrary
    private var restoring = false
    private var subscriptions: [AnyCancellable] = []
    private var mouseMonitor: Any?

    init(library: RecordingLibrary) {
        self.library = library
        let changes: [AnyPublisher<Void, Never>] = [
            library.$section.map { _ in }.eraseToAnyPublisher(),
            library.$selection.map { _ in }.eraseToAnyPublisher(),
            JiraPageModel.shared.$selected.map { _ in }.eraseToAnyPublisher(),
            GitHubModel.shared.$selectedURL.map { _ in }.eraseToAnyPublisher(),
            AgentHub.shared.$selected.map { _ in }.eraseToAnyPublisher(),
        ]
        subscriptions = [Publishers.MergeMany(changes).receive(on: DispatchQueue.main).sink { [weak self] in self?.record() }]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(mouseButton: event) ?? event }
        }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    private func handle(mouseButton event: NSEvent) -> NSEvent? {
        guard event.window?.contentViewController is NSHostingController<MainView> else { return event }
        switch event.buttonNumber {
        case 3 where canGoBack: back()
        case 4 where canGoForward: forward()
        default: return event
        }
        return nil
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func back() { history.back().map(restore) }

    func forward() { history.forward().map(restore) }

    private var place: NavigationPlace {
        let section = library.section
        switch section {
        case .meetings: return NavigationPlace(section: section, item: library.selection?.lastPathComponent)
        case .jira: return NavigationPlace(section: section, item: JiraPageModel.shared.selected)
        case .gitHub: return NavigationPlace(section: section, item: GitHubModel.shared.selectedURL)
        case .agent: return NavigationPlace(section: section, item: AgentHub.shared.selected)
        default: return NavigationPlace(section: section)
        }
    }

    private func record() {
        guard !restoring, library.section != .settings else { return }
        history.push(place)
    }

    private func restore(_ place: NavigationPlace) {
        restoring = true
        defer { DispatchQueue.main.async { self.restoring = false } }
        library.show(place.section)
        guard let item = place.item else { return }
        switch place.section {
        case .meetings: library.selection = library.recordings.first { $0.id.lastPathComponent == item }?.id
        case .jira: JiraPageModel.shared.select(item)
        case .gitHub: GitHubModel.shared.select(GitHubModel.shared.prs.values.joined().first { $0.url == item })
        case .agent: AgentHub.shared.selected = item
        default: break
        }
    }
}
