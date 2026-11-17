import AppKit

/// A window of the menu-bar app: shows a Dock icon and comes to the front while any of these windows is open.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    private static var open = Set<ObjectIdentifier>()

    private let make: () -> NSWindow
    private let onClose: () -> Void
    private let opensFullScreen: () -> Bool
    private var window: NSWindow?

    init(opensFullScreen: @escaping () -> Bool = { false }, onClose: @escaping () -> Void = {}, make: @escaping () -> NSWindow) {
        self.make = make
        self.onClose = onClose
        self.opensFullScreen = opensFullScreen
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = make()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        Self.open.insert(ObjectIdentifier(self))
        let enterFullScreen = window.map {
            MainWindowFullScreen.shouldEnter(enabled: opensFullScreen(), wasVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized,
                                             isFullScreen: $0.styleMask.contains(.fullScreen))
        } ?? false
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if enterFullScreen { window?.toggleFullScreen(nil) }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        Self.open.remove(ObjectIdentifier(self))
        if Self.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
