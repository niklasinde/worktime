import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func place(_ section: SidebarSection, _ item: String? = nil) -> NavigationPlace { NavigationPlace(section: section, item: item) }

let navigationTests: [(name: String, run: () throws -> Void)] = [
    ("history goes back and forward through the places visited", {
        var history = NavigationHistory()
        history.push(place(.meetings, "a"))
        history.push(place(.jira, "ACME-1"))
        history.push(place(.gitHub, "pr"))
        check(history.back() == place(.jira, "ACME-1"), "back once")
        check(history.back() == place(.meetings, "a"), "back twice")
        check(history.back() == nil && !history.canGoBack, "nothing before the first")
        check(history.forward() == place(.jira, "ACME-1"), "forward")
        check(history.canGoForward, "one more ahead")
    }),

    ("history ignores the same place twice and drops what was ahead on a new visit", {
        var history = NavigationHistory()
        history.push(place(.jira, "A"))
        history.push(place(.jira, "A"))
        history.push(place(.jira, "B"))
        check(history.places.count == 2, "duplicate collapsed")
        _ = history.back()
        history.push(place(.activity))
        check(history.places == [place(.jira, "A"), place(.activity)], "forward dropped: \(history.places)")
        check(!history.canGoForward, "nothing ahead")
    }),

    ("history keeps only the latest places", {
        var history = NavigationHistory()
        for number in 0..<(NavigationHistory.limit + 10) { history.push(place(.jira, "\(number)")) }
        check(history.places.count == NavigationHistory.limit, "capped")
        check(history.current == place(.jira, "\(NavigationHistory.limit + 9)"), "newest kept")
        check(history.places.first == place(.jira, "10"), "oldest dropped")
    }),
]
