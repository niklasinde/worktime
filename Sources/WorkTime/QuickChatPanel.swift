import AppKit
import SwiftUI

/// A panel that opens above any app on a global shortcut, for a short conversation with Main.
@MainActor
final class QuickChatPanel: ObservableObject {
    static let shared = QuickChatPanel()
    static let width: CGFloat = 680

    /// Why the shortcut may not work, nil when it should.
    @Published private(set) var note: String?
    @Published private(set) var workspace: String?
    private var hotKey: GlobalHotKey?
    private var registered: QuickShortcut?
    private var panel: QuickPanel?
    private var topLeft = NSPoint.zero
    private var observers: [NSObjectProtocol] = []

    var model: AgentModel? { workspace.flatMap { AgentHub.shared.mains[$0] } }
    var isShown: Bool { panel?.isVisible == true }

    /// The workspaces whose Main the panel can talk to.
    var choices: [(id: String, name: String)] {
        let names = Dictionary(WorkspaceStore.shared.workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return AgentHub.shared.mains.keys.sorted().map { ($0, names[$0] ?? $0) }
    }

    func start() {
        UserDefaults.standard.register(defaults: [QuickChat.enabledKey: true, QuickChat.allSpacesKey: true])
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickChatPanel.shared.apply() }
        })
        apply()
    }

    /// Registers the shortcut the settings name, or takes it back when the panel is switched off.
    func apply() {
        let defaults = UserDefaults.standard
        let wanted = defaults.bool(forKey: QuickChat.enabledKey) ? QuickShortcut.stored(defaults) : nil
        guard wanted != registered else { return }
        hotKey?.unregister()
        hotKey = nil
        registered = wanted
        guard let wanted else {
            hide()
            note = nil
            return
        }
        hotKey = GlobalHotKey(keyCode: UInt32(wanted.keyCode), modifiers: UInt32(wanted.modifiers)) { [weak self] in self?.toggle() }
        refreshNote()
    }

    /// Looks at the system's shortcuts again, which the user may have changed since.
    func refreshNote() {
        guard let registered, let hotKey else { return note = nil }
        note = QuickShortcutConflict.note(registration: hotKey.status, system: QuickShortcutConflict.system(registered, in: Self.systemHotKeys()))
    }

    private static func systemHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    #if DEBUG
    func preview(workspace id: String) { workspace = id }
    #endif

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        let hub = AgentHub.shared
        workspace = QuickChat.target(last: Workspaces.id(ofMainKey: hub.currentMainKey), available: hub.mains.keys.sorted())
        guard let model else { return }
        model.loadFiles()
        let panel = self.panel ?? makePanel()
        panel.collectionBehavior = [UserDefaults.standard.bool(forKey: QuickChat.allSpacesKey) ? .canJoinAllSpaces : .moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: QuickChatView(panel: self))
        host.sizingOptions = .intrinsicContentSize
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        model.setQuickShown(true)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model?.setQuickShown(false)
    }

    /// Switches the conversation to another workspace's Main.
    func select(_ id: String) {
        guard id != workspace, AgentHub.shared.mains[id] != nil else { return }
        model?.setQuickShown(false)
        workspace = id
        model?.loadFiles()
        model?.setQuickShown(true)
    }

    /// Shows the conversation on the Main page of the main window, where Back returns to where the user was.
    func openInApp() {
        guard let model else { return }
        hide()
        NSApp.activate(ignoringOtherApps: true)
        AgentHub.shared.show(model.attentionID)
    }

    /// A fifth of the way down the screen the pointer is on, where Spotlight sits.
    private func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        topLeft = NSPoint(x: area.midX - panel.frame.width / 2, y: area.maxY - area.height * 0.2)
        panel.setFrameTopLeftPoint(topLeft)
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 80),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.onCancel = { [weak self] in self?.hide() }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepTop() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resigned() }
        })
        self.panel = panel
        return panel
    }

    /// The hosting view grows the panel from its bottom edge; the top stays where it opened.
    private func keepTop() {
        guard let panel, panel.isVisible, abs(panel.frame.maxY - topLeft.y) > 0.5 else { return }
        panel.setFrameTopLeftPoint(topLeft)
    }

    /// Clicking another app closes the panel; a popover or menu of its own does not.
    private func resigned() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel, panel.isVisible, !panel.isKeyWindow else { return }
            if let key = NSApp.keyWindow, key.parent === panel || panel.childWindows?.contains(key) == true { return }
            hide()
        }
    }
}

private final class QuickPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { return onCancel() }
        super.sendEvent(event)
    }
}
