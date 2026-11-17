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
]
