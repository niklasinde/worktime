import Foundation

/// A global shortcut as Carbon takes it: a key code and Carbon's modifier masks.
struct QuickShortcut: Equatable, Sendable {
    static let keyCodeKey = "quickChatKeyCode"
    static let modifiersKey = "quickChatModifiers"

    static let control = 4096, option = 2048, shift = 512, command = 256
    static let standard = QuickShortcut(keyCode: 49, modifiers: control)

    /// What `NSEvent.ModifierFlags` and the system's own shortcut list call the same modifiers.
    private static let eventMasks: [(carbon: Int, event: Int)] = [(control, 1 << 18), (option, 1 << 19), (shift, 1 << 17), (command, 1 << 20)]
    private static let functionKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    var keyCode: Int
    var modifiers: Int

    /// From a key press: nil when it is not a key a shortcut can use, or has no modifier that keeps it from being typing.
    init?(keyCode: Int, eventFlags: Int) {
        let modifiers = Self.eventMasks.reduce(0) { $0 | (eventFlags & $1.event != 0 ? $1.carbon : 0) }
        self.init(keyCode: keyCode, modifiers: modifiers)
        guard isValid else { return nil }
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }

    /// Control or Command, two modifiers, or a function key: anything else would take a key away from typing.
    var isValid: Bool {
        guard Self.keyNames[keyCode] != nil else { return false }
        let held = [Self.control, Self.option, Self.shift, Self.command].filter { modifiers & $0 != 0 }
        return isFunctionKey || modifiers & (Self.control | Self.command) != 0 || held.count >= 2
    }

    /// The modifiers as the system's own shortcut list stores them.
    var eventFlags: Int { Self.eventMasks.reduce(0) { $0 | (modifiers & $1.carbon != 0 ? $1.event : 0) } }

    var label: String {
        let glyphs = [(Self.control, "\u{2303}"), (Self.option, "\u{2325}"), (Self.shift, "\u{21E7}"), (Self.command, "\u{2318}")]
        let prefix = glyphs.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        let key = Self.keyNames[keyCode] ?? "?"
        return prefix + (key.count > 1 && !isFunctionKey ? " " : "") + key
    }

    static func stored(_ defaults: UserDefaults = .standard) -> QuickShortcut {
        guard defaults.object(forKey: keyCodeKey) != nil else { return standard }
        let stored = QuickShortcut(keyCode: defaults.integer(forKey: keyCodeKey), modifiers: defaults.integer(forKey: modifiersKey))
        return stored.isValid ? stored : standard
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(keyCode, forKey: Self.keyCodeKey)
        defaults.set(modifiers, forKey: Self.modifiersKey)
    }
}

/// Shortcuts macOS itself reserves, which Carbon cannot take from it: the system's list in `com.apple.symbolichotkeys`.
enum QuickShortcutConflict {
    static let names: [String: String] = [
        "60": "Select the previous input source", "61": "Select the next source in the input menu",
        "64": "Spotlight search", "65": "Spotlight Finder search window",
    ]

    /// The name of the enabled system shortcut that uses `shortcut`, nil when none does.
    static func system(_ shortcut: QuickShortcut, in hotKeys: [String: Any]?) -> String? {
        let mask = QuickShortcut(keyCode: 0, modifiers: QuickShortcut.control | QuickShortcut.option | QuickShortcut.shift | QuickShortcut.command).eventFlags
        for (id, value) in (hotKeys ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Any], parameters.count >= 3,
                  let key = (parameters[1] as? NSNumber)?.intValue, let flags = (parameters[2] as? NSNumber)?.intValue,
                  key == shortcut.keyCode, flags & mask == shortcut.eventFlags else { continue }
            return names[id] ?? "a macOS shortcut"
        }
        return nil
    }

    /// Why the shortcut may not work, from what registering it and the system's list said; nil when it should.
    static func note(registration: Int32, system: String?) -> String? {
        if registration == -9878 { return "Another app already uses this shortcut." }
        if registration != 0 { return "macOS did not accept this shortcut." }
        return system.map { "macOS uses this shortcut for \u{201C}\($0)\u{201D}, so it may not reach WorkTime." }
    }
}

enum QuickChat {
    static let enabledKey = "quickChatEnabled"
    static let allSpacesKey = "quickChatAllSpaces"
    static let placeholder = "What can I help you with today?"
    /// A conversation quiet for this long is not shown when the panel opens, so it starts clean.
    static let staleAfter: TimeInterval = 600

    /// What the panel's transcript shows: with `expanded` the whole conversation, otherwise the turn the user started last. A turn that
    /// has ended and been quiet for `staleAfter` seconds is left out, unless a call still waits for an answer.
    static func shown(_ items: [AgentItem], expanded: Bool, busy: Bool, updated: Date?, now: Date) -> [AgentItem] {
        if expanded { return items }
        guard let last = items.lastIndex(where: { if case .user = $0.kind { true } else { false } }) else { return [] }
        let turn = Array(items[last...])
        let asking = turn.contains { if case .permission(_, _, _, _, nil) = $0.kind { true } else { false } }
        if busy || asking { return turn }
        guard let updated, now.timeIntervalSince(updated) < staleAfter else { return [] }
        return turn
    }

    /// Whether the full conversation has more than the panel shows.
    static func hasMore(_ items: [AgentItem], shown: [AgentItem]) -> Bool { items.count > shown.count }

    /// The workspace the panel talks to: the one last used if it is still there, otherwise the first.
    static func target(last: String?, available: [String]) -> String? {
        last.flatMap { available.contains($0) ? $0 : nil } ?? available.first
    }
}
