import Foundation

/// Somewhere in the main window: a page and, on pages that open one, the item shown.
struct NavigationPlace: Equatable {
    var section: SidebarSection
    var item: String?
}

/// The places visited, like a browser's back and forward.
struct NavigationHistory: Equatable {
    static let limit = 50

    private(set) var places: [NavigationPlace] = []
    private(set) var index = -1

    var current: NavigationPlace? { places.indices.contains(index) ? places[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < places.count - 1 }

    /// Records a visit: the same place twice in a row is one visit, and going somewhere new drops what was ahead.
    mutating func push(_ place: NavigationPlace) {
        guard place != current else { return }
        places.removeSubrange((index + 1)...)
        places.append(place)
        if places.count > Self.limit { places.removeFirst(places.count - Self.limit) }
        index = places.count - 1
    }

    mutating func back() -> NavigationPlace? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func forward() -> NavigationPlace? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}
