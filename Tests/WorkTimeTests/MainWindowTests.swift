import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let mainWindowTests: [(name: String, run: () throws -> Void)] = [
    ("main window: full screen is on unless the user turned it off", {
        let defaults = UserDefaults(suiteName: "mainWindowTests-\(UUID().uuidString)")!
        check(MainWindowFullScreen.enabled(defaults: defaults), "on by default")
        defaults.set(false, forKey: MainWindowFullScreen.key)
        check(!MainWindowFullScreen.enabled(defaults: defaults), "off when set")
        defaults.set(true, forKey: MainWindowFullScreen.key)
        check(MainWindowFullScreen.enabled(defaults: defaults), "on when set")
    }),
    ("main window: a window that was not on screen opens in full screen", {
        check(MainWindowFullScreen.shouldEnter(enabled: true, wasVisible: false, isMiniaturized: false, isFullScreen: false), "opening")
    }),
    ("main window: an open window brought to the front is not forced back into full screen", {
        check(!MainWindowFullScreen.shouldEnter(enabled: true, wasVisible: true, isMiniaturized: false, isFullScreen: false), "visible")
    }),
    ("main window: a minimised or already full-screen window and the off setting are left alone", {
        check(!MainWindowFullScreen.shouldEnter(enabled: true, wasVisible: false, isMiniaturized: true, isFullScreen: false), "minimised")
        check(!MainWindowFullScreen.shouldEnter(enabled: true, wasVisible: false, isMiniaturized: false, isFullScreen: true), "full screen")
        check(!MainWindowFullScreen.shouldEnter(enabled: false, wasVisible: false, isMiniaturized: false, isFullScreen: false), "off")
    }),
]
