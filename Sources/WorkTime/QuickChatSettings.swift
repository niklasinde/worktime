import AppKit
import SwiftUI

/// Settings → Agent: the shortcut that opens the quick chat panel.
struct QuickChatSettings: View {
    @AppStorage(QuickChat.enabledKey) private var enabled = true
    @AppStorage(QuickChat.allSpacesKey) private var allSpaces = true
    @AppStorage(QuickShortcut.keyCodeKey) private var keyCode = QuickShortcut.standard.keyCode
    @AppStorage(QuickShortcut.modifiersKey) private var modifiers = QuickShortcut.standard.modifiers
    @ObservedObject private var panel = QuickChatPanel.shared

    private var shortcut: QuickShortcut {
        let stored = QuickShortcut(keyCode: keyCode, modifiers: modifiers)
        return stored.isValid ? stored : .standard
    }

    var body: some View {
        SettingsSection("Quick chat", footer: "A panel above any app for a short conversation with Main. The shortcut or Esc closes it, and Open in WorkTime continues on the Main page. "
                        + "Approvals show in the panel; closed, they come as notifications.") {
            SettingsRow("Open with a shortcut") { Toggle("Open with a shortcut", isOn: $enabled).labelsHidden() }
            SettingsRow("Shortcut", detail: "Control or Command with a key, or a function key.") {
                HStack {
                    ShortcutRecorder(shortcut: shortcut) { chosen in
                        keyCode = chosen.keyCode
                        modifiers = chosen.modifiers
                    }
                    Button("Reset") {
                        keyCode = QuickShortcut.standard.keyCode
                        modifiers = QuickShortcut.standard.modifiers
                    }
                    .disabled(shortcut == .standard)
                }
            }
            .disabled(!enabled)
            if enabled, let note = panel.note {
                HStack {
                    Label(note, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    Spacer()
                    Button("Keyboard Shortcuts\u{2026}") { Self.openKeyboardSettings() }
                }
            }
            SettingsRow("Show on every Space", detail: "Off: it opens on the Space you are on and stays there.") {
                Toggle("Show on every Space", isOn: $allSpaces).labelsHidden()
            }
            if shortcut == .standard {
                SettingsRow("Control Space", detail: "macOS also uses it to switch input source when you have more than one. Turn that off under Input Sources.") {
                    Button("Keyboard Shortcuts\u{2026}") { Self.openKeyboardSettings() }
                }
            }
        }
        .onAppear { panel.refreshNote() }
    }

    private static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

/// A button that records the next shortcut typed while it is on.
struct ShortcutRecorder: View {
    let shortcut: QuickShortcut
    let onChange: (QuickShortcut) -> Void
    @State private var recording = false
    @State private var problem: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Type a shortcut\u{2026}" : shortcut.label).frame(minWidth: 110)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let flags = Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            if let found = QuickShortcut(keyCode: Int(event.keyCode), eventFlags: flags) {
                onChange(found)
                stop()
            } else {
                problem = "Hold \u{2303} or \u{2318}, or two modifiers."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
