import Foundation

/// Whether the main window opens maximised: the full width and height of the screen it opens on, below the menu bar.
enum MainWindowMaximised {
    static let key = "mainWindowMaximised"

    /// On unless the user turned it off.
    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Only a window that was not on screen is maximised: bringing an open window to the front, a window the user resized
    /// while it was open, a minimised one and one in full screen are left as they are.
    static func shouldMaximise(enabled: Bool, wasVisible: Bool, isMiniaturized: Bool, isFullScreen: Bool) -> Bool {
        enabled && !wasVisible && !isMiniaturized && !isFullScreen
    }

    /// The visible area of the screen the pointer is on, else of the first one: where a window that opens fills.
    static func target(mouse: CGPoint, screens: [(frame: CGRect, visible: CGRect)]) -> CGRect? {
        (screens.first { $0.frame.contains(mouse) } ?? screens.first)?.visible
    }
}
