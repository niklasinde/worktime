import Foundation

struct ChromeProfile: Equatable, Identifiable, Sendable {
    let directory: String
    let name: String
    let email: String?

    var id: String { directory }
    var label: String { email.map { "\(name) (\($0))" } ?? name }
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

    static func load(from url: URL = localState) -> [ChromeProfile] {
        (try? Data(contentsOf: url)).map(parse) ?? []
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
