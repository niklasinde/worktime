import Foundation

struct ChromeProfile: Codable, Equatable, Identifiable, Sendable {
    let directory: String
    let name: String
    let email: String?

    var id: String { directory.isEmpty ? "name:" + name : directory }
    var label: String { email.map { "\(name) (\($0))" } ?? name }
}

/// Whether Chrome's profile list could be read: macOS keeps one app's data from another unless it is allowed.
enum ChromeAccess: Equatable, Sendable { case readable, denied, missing, unreadable }

/// The profiles WorkTime knows from Chrome's Local State, fresh when it could be read and the last ones it saw otherwise.
struct ChromeProfileList: Equatable, Sendable {
    var profiles: [ChromeProfile]
    var access: ChromeAccess

    var fromCache: Bool { access != .readable && !profiles.isEmpty }

    /// What to tell the user under the picker, nil when there is nothing to add.
    var note: String? {
        let cached = fromCache ? " Showing the profiles seen last time." : ""
        switch access {
        case .readable:
            switch profiles.count {
            case 0: return "Chrome has no profiles in its list."
            case 1: return "Chrome has one profile, so there is nothing to choose between."
            default: return nil
            }
        case .denied:
            return "macOS keeps WorkTime from reading Chrome\u{2019}s profile list. Choose Chrome\u{2019}s Local State file, give WorkTime Full Disk Access, "
                + "or add the profile\u{2019}s name." + cached
        case .missing:
            return "Chrome\u{2019}s profile list was not found: Chrome may not be installed or opened yet." + cached
        case .unreadable:
            return "Chrome\u{2019}s profile list could not be read." + cached
        }
    }
}

/// Which Chrome profile a window belongs to. Chrome gives no scripting access to it, but once more than one profile
/// exists it appends the profile's name to the window title ("Page - Google Chrome - Work"). A window whose profile
/// cannot be told is never counted for a chosen profile.
enum ChromeProfiles {
    static let bundle = "com.google.Chrome"
    static let titleMarker = " - Google Chrome - "
    static let refreshInterval: TimeInterval = 60

    static var localState: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    static let cacheKey = "activityChromeProfilesCache"
    static let seenKey = "activityChromeProfilesSeen"
    static let addedKey = "activityChromeProfilesAdded"
    static let nameLimit = 20

    static func load(from url: URL = localState) -> [ChromeProfile] {
        (try? Data(contentsOf: url)).map(parse) ?? []
    }

    static func access(for error: Error) -> ChromeAccess {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError), (NSPOSIXErrorDomain, 1), (NSPOSIXErrorDomain, 13): return .denied
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSPOSIXErrorDomain, 2): return .missing
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return access(for: underlying) }
            return .unreadable
        }
    }

    /// Reads Local State and keeps its profiles for when macOS later refuses; unreadable, the kept ones are returned.
    static func refresh(from url: URL = localState, defaults: UserDefaults = .standard) -> ChromeProfileList {
        do {
            let profiles = parse(try Data(contentsOf: url))
            remember(profiles, defaults: defaults)
            return ChromeProfileList(profiles: profiles, access: .readable)
        } catch {
            return ChromeProfileList(profiles: cached(defaults: defaults), access: access(for: error))
        }
    }

    /// A Local State file the user picked, which macOS lets WorkTime read once: its profiles are kept.
    static func adopt(_ data: Data, defaults: UserDefaults = .standard) -> [ChromeProfile] {
        let profiles = parse(data)
        if !profiles.isEmpty { remember(profiles, defaults: defaults) }
        return profiles
    }

    static func cached(defaults: UserDefaults = .standard) -> [ChromeProfile] {
        defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode([ChromeProfile].self, from: $0) } ?? []
    }

    private static func remember(_ profiles: [ChromeProfile], defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(profiles), forKey: cacheKey)
    }

    /// Notes the profile name a Chrome window title shows, so it can be chosen even when Local State is unreadable.
    static func learn(fromTitle title: String?, defaults: UserDefaults = .standard) {
        guard let title, !isPrivate(title: title), let name = profileName(inTitle: title) else { return }
        add(name: name, key: seenKey, defaults: defaults)
    }

    static func add(name: String, key: String = addedKey, defaults: UserDefaults = .standard) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = defaults.stringArray(forKey: key) ?? []
        guard !name.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        names.append(name)
        defaults.set(Array(names.suffix(nameLimit)), forKey: key)
    }

    /// The picker's profiles: Local State's, then names seen in titles or typed in that it does not list.
    static func choices(known: [ChromeProfile], defaults: UserDefaults = .standard) -> [ChromeProfile] {
        let extra = ((defaults.stringArray(forKey: seenKey) ?? []) + (defaults.stringArray(forKey: addedKey) ?? []))
            .filter { name in !known.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        var seen: [String] = []
        let named = extra.sorted { $0.lowercased() < $1.lowercased() }.filter { name in
            defer { seen.append(name.lowercased()) }
            return !seen.contains(name.lowercased())
        }
        return known + named.map { ChromeProfile(directory: "", name: $0, email: nil) }
    }

    static func parse(_ data: Data) -> [ChromeProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        return cache.compactMap { directory, info -> ChromeProfile? in
            guard let name = (info["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ChromeProfile(directory: directory, name: name, email: email)
        }
        .sorted { ($0.name.lowercased(), $0.directory) < ($1.name.lowercased(), $1.directory) }
    }

    /// The profile name Chrome appended to the window title, nil when it appended none.
    static func profileName(inTitle title: String) -> String? {
        guard let range = title.range(of: titleMarker, options: .backwards) else { return nil }
        let name = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func isPrivate(title: String) -> Bool {
        title.hasSuffix("(Incognito)") || title.hasSuffix(" - Guest") || title.hasSuffix("(Guest)")
    }

    /// Whether the window counts when only `chosen` (a profile name, empty for all) is tracked. Without a name in the
    /// title that is only certain when `chosen` is the one profile Chrome has.
    static func allows(title: String?, chosen: String, profiles: [ChromeProfile]) -> Bool {
        let chosen = chosen.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { return true }
        func same(_ name: String) -> Bool { name.caseInsensitiveCompare(chosen) == .orderedSame }
        if let title, isPrivate(title: title) { return false }
        if let name = title.flatMap(profileName(inTitle:)) { return same(name) }
        return profiles.count == 1 && same(profiles[0].name)
    }
}
