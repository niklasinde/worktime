import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func user(_ id: Int = 0) -> AgentItem { AgentItem(id: "user-\(id)", kind: .user("Hi")) }
private func reply(_ id: Int) -> AgentItem { AgentItem(id: "text-\(id)", kind: .text("Hello")) }
private func asking(_ answer: Bool?) -> AgentItem {
    AgentItem(id: "permission-1", kind: .permission(tool: "Bash", summary: "ls", detail: "", allowed: answer))
}

private let ctrlSpaceFlags = 1 << 18

let quickChatTests: [(name: String, run: () throws -> Void)] = [
    ("quick chat: Control and Space is the default, and reads as such", {
        check(QuickShortcut.standard == QuickShortcut(keyCode: 49, modifiers: QuickShortcut.control), "standard")
        check(QuickShortcut.standard.label == "\u{2303} Space", QuickShortcut.standard.label)
        check(QuickShortcut(keyCode: 15, modifiers: QuickShortcut.control | QuickShortcut.option | QuickShortcut.command).label == "\u{2303}\u{2325}\u{2318}R", "letter")
        check(QuickShortcut(keyCode: 96, modifiers: 0).label == "F5", "function key")
    }),
    ("quick chat: a shortcut needs Control or Command, two modifiers, or a function key, so it never takes a key from typing", {
        check(QuickShortcut(keyCode: 49, eventFlags: ctrlSpaceFlags) == .standard, "control and space from a key press")
        check(QuickShortcut(keyCode: 0, eventFlags: 0) == nil, "a bare letter")
        check(QuickShortcut(keyCode: 0, eventFlags: 1 << 17) == nil, "shift alone")
        check(QuickShortcut(keyCode: 0, eventFlags: 1 << 19) == nil, "option alone")
        check(QuickShortcut(keyCode: 0, eventFlags: (1 << 19) | (1 << 17)) != nil, "option and shift")
        check(QuickShortcut(keyCode: 0, eventFlags: 1 << 20)?.modifiers == QuickShortcut.command, "command")
        check(QuickShortcut(keyCode: 96, eventFlags: 0) != nil, "a function key alone")
        check(QuickShortcut(keyCode: 53, eventFlags: ctrlSpaceFlags) == nil, "escape is not a key a shortcut can use")
        check(QuickShortcut.standard.eventFlags == ctrlSpaceFlags, "the modifiers go back to the system's form")
    }),
    ("quick chat: the stored shortcut falls back to the default when missing or unusable", {
        let defaults = UserDefaults(suiteName: "quick-chat-tests-\(UUID().uuidString)")!
        check(QuickShortcut.stored(defaults) == .standard, "nothing stored")
        let chosen = QuickShortcut(keyCode: 49, modifiers: QuickShortcut.command | QuickShortcut.option)
        chosen.save(to: defaults)
        check(QuickShortcut.stored(defaults) == chosen, "saved")
        QuickShortcut(keyCode: 0, modifiers: 0).save(to: defaults)
        check(QuickShortcut.stored(defaults) == .standard, "a bare letter is not kept")
    }),
    ("quick chat: it finds the enabled system shortcut that holds the same keys", {
        let list: [String: Any] = [
            "60": ["enabled": 1, "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
            "61": ["enabled": 0, "value": ["parameters": [32, 49, 786_432], "type": "standard"]],
            "64": ["enabled": 1, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]],
        ]
        check(QuickShortcutConflict.system(.standard, in: list) == "Select the previous input source", "control and space")
        check(QuickShortcutConflict.system(QuickShortcut(keyCode: 49, modifiers: QuickShortcut.command), in: list) == "Spotlight search", "command and space")
        check(QuickShortcutConflict.system(QuickShortcut(keyCode: 49, modifiers: QuickShortcut.control | QuickShortcut.option), in: list) == nil,
              "turned off")
        check(QuickShortcutConflict.system(QuickShortcut(keyCode: 15, modifiers: QuickShortcut.control), in: list) == nil, "another key")
        check(QuickShortcutConflict.system(.standard, in: nil) == nil, "no list")
    }),
    ("quick chat: the note says why a shortcut may not work", {
        check(QuickShortcutConflict.note(registration: 0, system: nil) == nil, "fine")
        check(QuickShortcutConflict.note(registration: -9878, system: nil) == "Another app already uses this shortcut.", "taken")
        check(QuickShortcutConflict.note(registration: -50, system: nil) == "macOS did not accept this shortcut.", "refused")
        check(QuickShortcutConflict.note(registration: 0, system: "Spotlight search")?.contains("Spotlight search") == true, "system")
    }),
    ("quick chat: it shows the turn just started, and the whole conversation when expanded", {
        let items = [user(0), reply(0), user(1), reply(1)]
        check(QuickChat.shown(items, expanded: false, busy: true, updated: now, now: now).map(\.id) == ["user-1", "text-1"], "the last turn")
        check(QuickChat.shown(items, expanded: true, busy: false, updated: nil, now: now).count == 4, "everything")
        check(QuickChat.shown([], expanded: false, busy: true, updated: now, now: now).isEmpty, "nothing yet")
        check(QuickChat.shown([reply(0)], expanded: false, busy: true, updated: now, now: now).isEmpty, "no message from the user")
        check(QuickChat.hasMore(items, shown: QuickChat.shown(items, expanded: false, busy: true, updated: now, now: now)), "more to show")
    }),
    ("quick chat: a turn that ended long ago is left out, unless a call waits for an answer", {
        let items = [user(0), reply(0)]
        let recent = now.addingTimeInterval(-60), old = now.addingTimeInterval(-QuickChat.staleAfter - 1)
        check(QuickChat.shown(items, expanded: false, busy: false, updated: recent, now: now).count == 2, "recent")
        check(QuickChat.shown(items, expanded: false, busy: false, updated: old, now: now).isEmpty, "old")
        check(QuickChat.shown(items, expanded: false, busy: false, updated: nil, now: now).isEmpty, "never updated")
        let waiting = [user(0), asking(nil)]
        check(QuickChat.shown(waiting, expanded: false, busy: false, updated: old, now: now).count == 2, "a call waits")
        check(QuickChat.shown([user(0), asking(true)], expanded: false, busy: false, updated: old, now: now).isEmpty, "answered")
    }),
    ("quick chat: it talks to the workspace last used, or the first", {
        check(QuickChat.target(last: "b", available: ["a", "b"]) == "b", "last used")
        check(QuickChat.target(last: "gone", available: ["a", "b"]) == "a", "last one is gone")
        check(QuickChat.target(last: nil, available: ["a"]) == "a", "none used")
        check(QuickChat.target(last: "a", available: []) == nil, "no workspace")
    }),
]
