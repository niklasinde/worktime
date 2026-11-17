import AppKit

/// A window of the menu-bar app: shows a Dock icon and comes to the front while any of these windows is open.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    private static var open = Set<ObjectIdentifier>()

    private let make: () -> NSWindow
    private let onClose: () -> Void
    private let opensMaximised: () -> Bool
    private var window: NSWindow?

    init(opensMaximised: @escaping () -> Bool = { false }, onClose: @escaping () -> Void = {}, make: @escaping () -> NSWindow) {
        self.make = make
        self.onClose = onClose
        self.opensMaximised = opensMaximised
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
        if let window, MainWindowMaximised.shouldMaximise(enabled: opensMaximised(), wasVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                                                          isFullScreen: window.styleMask.contains(.fullScreen)),
           let frame = MainWindowMaximised.target(mouse: NSEvent.mouseLocation, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }) {
            window.setFrame(frame, display: false)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
