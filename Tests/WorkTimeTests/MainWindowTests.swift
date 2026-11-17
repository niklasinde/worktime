import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let mainWindowTests: [(name: String, run: () throws -> Void)] = [
    ("main window: opening maximised is on unless the user turned it off", {
        let defaults = UserDefaults(suiteName: "mainWindowTests-\(UUID().uuidString)")!
        check(MainWindowMaximised.enabled(defaults: defaults), "on by default")
        defaults.set(false, forKey: MainWindowMaximised.key)
        check(!MainWindowMaximised.enabled(defaults: defaults), "off when set")
        defaults.set(true, forKey: MainWindowMaximised.key)
        check(MainWindowMaximised.enabled(defaults: defaults), "on when set")
    }),
    ("main window: a window that was not on screen opens maximised", {
        check(MainWindowMaximised.shouldMaximise(enabled: true, wasVisible: false, isMiniaturized: false, isFullScreen: false), "opening")
    }),
    ("main window: an open window brought to the front keeps the size the user gave it", {
        check(!MainWindowMaximised.shouldMaximise(enabled: true, wasVisible: true, isMiniaturized: false, isFullScreen: false), "visible")
    }),
    ("main window: a minimised or full-screen window and the off setting are left alone", {
        check(!MainWindowMaximised.shouldMaximise(enabled: true, wasVisible: false, isMiniaturized: true, isFullScreen: false), "minimised")
        check(!MainWindowMaximised.shouldMaximise(enabled: true, wasVisible: false, isMiniaturized: false, isFullScreen: true), "full screen")
        check(!MainWindowMaximised.shouldMaximise(enabled: false, wasVisible: false, isMiniaturized: false, isFullScreen: false), "off")
    }),
    ("main window: it fills the visible area of the screen the pointer is on", {
        let left = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let right = (frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440), visible: CGRect(x: 1440, y: 0, width: 2560, height: 1415))
        check(MainWindowMaximised.target(mouse: CGPoint(x: 100, y: 100), screens: [left, right]) == left.visible, "left screen")
        check(MainWindowMaximised.target(mouse: CGPoint(x: 2000, y: 700), screens: [left, right]) == right.visible, "right screen")
        check(MainWindowMaximised.target(mouse: CGPoint(x: -50, y: -50), screens: [left, right]) == left.visible, "off every screen falls back to the first")
        check(MainWindowMaximised.target(mouse: .zero, screens: []) == nil, "no screens")
    }),
]
