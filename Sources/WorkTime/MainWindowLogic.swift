import Foundation

/// Whether the main window enters macOS full screen when it opens.
enum MainWindowFullScreen {
    static let key = "mainWindowFullScreen"

    /// On unless the user turned it off.
    static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Only a window that was not on screen goes full screen: bringing an open window to the front, a window the user
    /// took out of full screen or minimised, and one already in or entering full screen are left as they are.
    static func shouldEnter(enabled: Bool, wasVisible: Bool, isMiniaturized: Bool, isFullScreen: Bool) -> Bool {
        enabled && !wasVisible && !isMiniaturized && !isFullScreen
    }
}
