import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let work = ChromeProfile(directory: "Profile 1", name: "Work", email: "me@work.com")
private let home = ChromeProfile(directory: "Default", name: "Home", email: nil)

let chromeProfileTests: [(name: String, run: () throws -> Void)] = [
    ("the profiles come from Chrome's Local State, by name", {
        let json = """
        {"profile": {"info_cache": {"Profile 1": {"name": "Work", "user_name": "me@work.com"},
                                    "Default": {"name": "Home", "user_name": ""},
                                    "Broken": {"user_name": "x"}}}}
        """
        let profiles = ChromeProfiles.parse(Data(json.utf8))
        check(profiles == [home, work], "sorted by name, nameless dropped: \(profiles)")
        check(work.label == "Work (me@work.com)" && home.label == "Home", "labels")
        check(ChromeProfiles.parse(Data("nope".utf8)).isEmpty, "unreadable gives none")
    }),

    ("the profile name is the part after the last Google Chrome in the title", {
        check(ChromeProfiles.profileName(inTitle: "Inbox - Google Chrome - Work") == "Work", "suffix")
        check(ChromeProfiles.profileName(inTitle: "A - Google Chrome - B - Google Chrome - Person 1") == "Person 1", "last one")
        check(ChromeProfiles.profileName(inTitle: "Inbox - Google Chrome") == nil, "no suffix")
        check(ChromeProfiles.profileName(inTitle: "Inbox") == nil, "not a Chrome title")
    }),

    ("all profiles are tracked when none is chosen", {
        check(ChromeProfiles.allows(title: "Inbox - Google Chrome - Home", chosen: "", profiles: [home, work]), "no filter")
        check(ChromeProfiles.allows(title: nil, chosen: "  ", profiles: []), "blank filter")
    }),

    ("only the chosen profile's windows count", {
        let profiles = [home, work]
        check(ChromeProfiles.allows(title: "Inbox - Google Chrome - Work", chosen: "Work", profiles: profiles), "its own window")
        check(ChromeProfiles.allows(title: "Inbox - Google Chrome - work", chosen: "Work", profiles: profiles), "case ignored")
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome - Home", chosen: "Work", profiles: profiles), "another profile")
    }),

    ("a window whose profile is unknown is not tracked unless it is the only profile", {
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome", chosen: "Work", profiles: [home, work]), "several profiles")
        check(!ChromeProfiles.allows(title: nil, chosen: "Work", profiles: [home, work]), "no title")
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome", chosen: "Work", profiles: []), "profiles unreadable")
        check(ChromeProfiles.allows(title: "Inbox - Google Chrome", chosen: "Work", profiles: [work]), "the only profile")
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome", chosen: "Work", profiles: [home]), "the only profile is another")
    }),

    ("incognito and guest windows are not tracked for a chosen profile", {
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome (Incognito)", chosen: "Work", profiles: [work]), "incognito")
        check(!ChromeProfiles.allows(title: "Inbox - Google Chrome - Guest", chosen: "Work", profiles: [work]), "guest")
    }),

    ("the chosen profile is a setting, empty by default", {
        let defaults = UserDefaults(suiteName: "chrome-profile-tests")!
        defaults.removePersistentDomain(forName: "chrome-profile-tests")
        check(ActivitySettings(defaults).chromeProfile.isEmpty, "all profiles by default")
        defaults.set("Work", forKey: ActivitySettings.chromeProfileKey)
        check(ActivitySettings(defaults).chromeProfile == "Work", "read back")
        defaults.removePersistentDomain(forName: "chrome-profile-tests")
    }),

    ("a refused read is told from a missing file", {
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)])
        check(ChromeProfiles.access(for: denied) == .denied, "no permission")
        check(ChromeProfiles.access(for: wrapped) == .denied, "operation not permitted underneath")
        check(ChromeProfiles.access(for: missing) == .missing, "no file")
        check(ChromeProfiles.access(for: NSError(domain: "other", code: 5)) == .unreadable, "anything else")
    }),

    ("the picker explains why it may be empty", {
        check(ChromeProfileList(profiles: [work, home], access: .readable).note == nil, "several profiles need no note")
        check(ChromeProfileList(profiles: [work], access: .readable).note?.contains("one profile") == true, "just one")
        check(ChromeProfileList(profiles: [], access: .readable).note?.contains("no profiles") == true, "none")
        let denied = ChromeProfileList(profiles: [], access: .denied)
        check(denied.note?.contains("Full Disk Access") == true && !denied.fromCache, "refused")
        let cached = ChromeProfileList(profiles: [work], access: .denied)
        check(cached.fromCache && cached.note?.contains("seen last time") == true, "kept profiles")
        check(ChromeProfileList(profiles: [], access: .missing).note?.contains("not found") == true, "missing")
    }),

    ("profiles read once are kept for when macOS refuses", {
        let defaults = UserDefaults(suiteName: "chrome-profile-cache-tests")!
        defaults.removePersistentDomain(forName: "chrome-profile-cache-tests")
        let json = #"{"profile": {"info_cache": {"Profile 1": {"name": "Work", "user_name": "me@work.com"}, "Default": {"name": "Home"}}}}"#
        check(ChromeProfiles.adopt(Data(json.utf8), defaults: defaults) == [home, work], "picked file read")
        let gone = URL(fileURLWithPath: "/nonexistent/Local State")
        let list = ChromeProfiles.refresh(from: gone, defaults: defaults)
        check(list.access == .missing && list.profiles == [home, work] && list.fromCache, "kept ones returned")
        check(ChromeProfiles.adopt(Data("nope".utf8), defaults: defaults).isEmpty, "bad file adds none")
        check(ChromeProfiles.cached(defaults: defaults) == [home, work], "bad file keeps the old ones")
        defaults.removePersistentDomain(forName: "chrome-profile-cache-tests")
    }),

    ("names seen in titles or typed in join the picker", {
        let defaults = UserDefaults(suiteName: "chrome-profile-names-tests")!
        defaults.removePersistentDomain(forName: "chrome-profile-names-tests")
        ChromeProfiles.learn(fromTitle: "Inbox - Google Chrome - Studio", defaults: defaults)
        ChromeProfiles.learn(fromTitle: "Inbox - Google Chrome - studio", defaults: defaults)
        ChromeProfiles.learn(fromTitle: "Inbox - Google Chrome (Incognito)", defaults: defaults)
        ChromeProfiles.learn(fromTitle: "Inbox - Google Chrome", defaults: defaults)
        ChromeProfiles.learn(fromTitle: nil, defaults: defaults)
        ChromeProfiles.add(name: "  Side  ", defaults: defaults)
        ChromeProfiles.add(name: " ", defaults: defaults)
        let choices = ChromeProfiles.choices(known: [work], defaults: defaults)
        check(choices.map(\.name) == ["Work", "Side", "Studio"], "known first, then the others by name: \(choices.map(\.name))")
        check(Set(choices.map(\.id)).count == 3, "each has its own id")
        check(ChromeProfiles.choices(known: [ChromeProfile(directory: "Default", name: "studio", email: nil)], defaults: defaults).map(\.name) == ["studio", "Side"], "a known name is not repeated")
        for index in 0..<30 { ChromeProfiles.add(name: "P\(index)", defaults: defaults) }
        check((defaults.stringArray(forKey: ChromeProfiles.addedKey) ?? []).count == ChromeProfiles.nameLimit, "capped")
        defaults.removePersistentDomain(forName: "chrome-profile-names-tests")
    }),
]
