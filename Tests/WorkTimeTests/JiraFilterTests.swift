import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func ticket(_ key: String, status: String = "In Progress", category: JiraStatusCategory = .inProgress, assignee: String? = nil,
                    assigneeID: String? = nil) -> JiraTicket {
    JiraTicket(key: key, summary: "S", status: status, priority: nil, updated: nil, assignee: assignee, assigneeID: assigneeID, category: category)
}

let jiraFilterTests: [(name: String, run: () throws -> Void)] = [
    ("filters build server-side JQL: projects and statuses together, quoted and escaped, with the tab's own condition", {
        check(JiraQuery.jql(.assigned, JiraFilter()) == JiraTab.assigned.jql, "no filter is the tab")
        check(JiraQuery.jql(.reported, JiraFilter()) == "reporter = currentUser() ORDER BY updated DESC", "reported")
        let jql = JiraQuery.jql(.watching, JiraFilter(project: "ISD, ACME", statusName: "Waiting for customer"))
        check(jql == "(watcher = currentUser()) AND project in (\"ISD\", \"ACME\") AND status = \"Waiting for customer\" ORDER BY updated DESC", jql)
        let odd = JiraQuery.jql(.reported, JiraFilter(statusName: "Say \"hi\" \\ now"))
        check(odd.contains(#"status = "Say \"hi\" \\ now""#), "quotes and backslashes are escaped: \(odd)")
        check(JiraQuery.jql(.reported, JiraFilter(sort: .priority)) == "reporter = currentUser() ORDER BY priority DESC, updated DESC", "priority order")
    }),

    ("the assignee filter replaces the Assigned tab's own assignee: me, unassigned, anyone and a person by account id", {
        check(JiraQuery.jql(.assigned, JiraFilter(assignee: "unassigned")) == "(resolution = Unresolved) AND assignee is EMPTY ORDER BY updated DESC", "unassigned")
        check(JiraQuery.jql(.assigned, JiraFilter(assignee: "anyone")) == "resolution = Unresolved ORDER BY updated DESC", "anyone")
        let person = JiraQuery.jql(.assigned, JiraFilter(assignee: "me, @557058:abc"))
        check(person == "(resolution = Unresolved) AND assignee in (currentUser(), \"557058:abc\") ORDER BY updated DESC", person)
        check(JiraQuery.jql(.reported, JiraFilter(assignee: "unassigned")) == "(reporter = currentUser()) AND assignee is EMPTY ORDER BY updated DESC", "other tabs keep theirs")
        check(JiraQuery.replacesAssignee(.assigned, JiraFilter(assignee: "me")) && !JiraQuery.replacesAssignee(.reported, JiraFilter(assignee: "me"))
              && !JiraQuery.replacesAssignee(.assigned, JiraFilter()), "replaces")
        check(JiraTickets.jql(.assigned, JiraFilter(project: "ACME", type: "Bug,Task"))
              == "(assignee = currentUser() AND resolution = Unresolved) AND project = \"ACME\" AND issuetype in (\"Bug\", \"Task\") ORDER BY updated DESC", "the page's query")
    }),

    ("the cached list answers unless a filter or the sort changes the query, and jql: runs a query of its own", {
        check(!JiraQuery.needsServer(JiraFilter()) && !JiraQuery.needsServer(JiraFilter(status: .inReview, query: "x")), "chips and text stay local")
        check(JiraQuery.needsServer(JiraFilter(project: "ISD")) && JiraQuery.needsServer(JiraFilter(sort: .priority)) && JiraQuery.needsServer(JiraFilter(assignee: "anyone")), "server")
        check(JiraQuery.raw("jql: project = ACME ORDER BY created") == "project = ACME ORDER BY created", "raw")
        check(JiraQuery.raw("  JQL:assignee is EMPTY ") == "assignee is EMPTY", "case and spacing")
        check(JiraQuery.raw("jql:") == nil && JiraQuery.raw("login") == nil, "nothing to run")
        check(JiraQuery.isRaw("jql:") && !JiraQuery.isRaw("jqlx"), "raw mode")
        check(JiraQuery.title(count: 3, capped: false, tab: .assigned, filter: JiraFilter()) == "3 assigned", "assigned")
        check(JiraQuery.title(count: 50, capped: true, tab: .assigned, filter: JiraFilter(assignee: "anyone")) == "50+ tickets", "replaced assignee")
        check(JiraQuery.title(count: 2, capped: false, tab: .assigned, filter: JiraFilter(query: "jql: a = b")) == "2 results", "raw title")
    }),

    ("choices toggle in a comma list ignoring case, and Anyone stands alone", {
        check(JiraChoices.toggled(nil, "ISD") == "ISD" && JiraChoices.toggled("ISD", "ACME") == "ISD, ACME", "add")
        check(JiraChoices.toggled("ISD, ACME", "isd") == "ACME" && JiraChoices.toggled("ISD", "ISD") == nil, "remove")
        check(JiraChoices.contains("ISD, ACME", "acme") && !JiraChoices.contains(nil, "ISD"), "contains")
        check(JiraAssignee.toggled(nil, "anyone") == "anyone" && JiraAssignee.toggled("anyone", "anyone") == nil, "anyone toggles")
        check(JiraAssignee.toggled("me", "unassigned") == "me, unassigned" && JiraAssignee.toggled("anyone", "me") == "me", "others replace anyone")
        check(JiraAssignee.toggled("me, unassigned", "anyone") == "anyone", "anyone clears the rest")
        let person = JiraPerson(id: "557058:abc", name: "Anna Berg")
        check(JiraAssignee.token(for: person) == "@557058:abc", "token")
        check(JiraAssignee.summary("me, @557058:abc, unassigned, @gone", people: ["557058:abc": "Anna Berg"]) == "Me, Anna Berg, Unassigned, Someone", "labels")
        check(JiraAssignee.queryValue("anyone") == nil && JiraAssignee.queryValue("me, @5:a") == "me, 5:a" && JiraAssignee.queryValue(nil) == nil, "query value")
    }),

    ("the status groups run in the order the work moves, the people come from the tickets, and chosen options stay on the menu", {
        let tickets = [ticket("A-1", status: "Done", category: .done), ticket("A-2", status: "To Do", category: .todo), ticket("A-3", status: "Review"),
                       ticket("A-4", status: "In Progress"), ticket("A-5", status: "In Progress")]
        let groups = JiraTickets.groups(tickets, by: .status)
        check(groups.map(\.title) == ["In Progress", "Review", "To Do", "Done"], "\(groups.map(\.title))")
        check(groups[0].tickets.map(\.key) == ["A-4", "A-5"], "order inside a group is kept")
        check(JiraTickets.groups(tickets, by: .none).map(\.tickets.count) == [5] && JiraTickets.groups([], by: .status).isEmpty, "no grouping")
        let people = JiraTickets.people([ticket("A-1", assignee: "Zed", assigneeID: "z"), ticket("A-2", assignee: "Anna", assigneeID: "a"),
                                         ticket("A-3", assignee: "Anna", assigneeID: "a"), ticket("A-4", assignee: "No id")])
        check(people == [JiraPerson(id: "a", name: "Anna"), JiraPerson(id: "z", name: "Zed")], "unique by id, by name")
        let options = JiraTickets.Options(projects: ["ISD"], statuses: ["Done"]).including(JiraFilter(project: "acme", statusName: "Done, Waiting"))
        check(options.projects == ["acme", "ISD"] && options.statuses == ["Done", "Waiting"], "\(options)")
        check(JiraQuery.projectChoices(configured: ["ACME", "ISD", "QPB"], seen: ["ZED", "ISD"], selected: "abc") == ["ACME", "ISD", "QPB", "ABC", "ZED"], "project choices")
        check(JiraQuery.projectChoices(configured: [], seen: ["b", "a"], selected: nil) == ["A", "B"], "without workspaces")
    }),

    ("saved views replace by name, drop the search text, are marked when shown and survive a restart", {
        let first = JiraSavedView(name: "ISD waiting on me", tab: .assigned, filter: JiraFilter(query: "login", project: "ISD", statusName: "Waiting for customer"))
        var views = JiraSavedViews.saving(first, in: [])
        check(views.count == 1 && views[0].filter.query == "", "the search text is not saved")
        views = JiraSavedViews.saving(JiraSavedView(name: " isd waiting on me ", tab: .reported, filter: JiraFilter()), in: views)
        check(views.count == 1 && views[0].tab == .reported && views[0].name == "isd waiting on me", "same name replaces")
        views = JiraSavedViews.saving(first, in: views)
        views = JiraSavedViews.saving(JiraSavedView(name: "Mine", tab: .assigned, filter: JiraFilter(assignee: "me")), in: views)
        check(views.map(\.name) == ["ISD waiting on me", "Mine"], "order")
        check(JiraSavedViews.saving(JiraSavedView(name: "  ", tab: .assigned, filter: JiraFilter()), in: views) == views, "no name, no view")
        check(JiraSavedViews.current(.assigned, JiraFilter(query: "x", project: "ISD", statusName: "Waiting for customer"), in: views)?.name == "ISD waiting on me", "current")
        check(JiraSavedViews.current(.assigned, JiraFilter(project: "ACME"), in: views) == nil, "no match")
        check(JiraSavedViews.decode(JiraSavedViews.encode(views)) == views, "round trip")
        check(JiraSavedViews.removing("MINE", from: views).map(\.name) == ["ISD waiting on me"], "removing")
        check(JiraSavedViews.decode(nil).isEmpty && JiraSavedViews.decode(Data("nope".utf8)).isEmpty, "bad file")
    }),

    ("the page remembers its tab and filters but not the search text, and an older file without the new keys still loads", {
        let state = JiraPageState(tab: .reported, filter: JiraFilter(status: .inReview, query: "login", project: "ACME", assignee: "unassigned", sort: .priority, group: .status))
        let back = JiraPageState.decode(JiraPageState.encode(state))
        check(back?.tab == .reported && back?.filter.query == "" && back?.filter.project == "ACME" && back?.filter.status == .inReview, "remembered")
        check(back?.filter.assignee == "unassigned" && back?.filter.sort == .priority && back?.filter.group == .status, "sort and group")
        let old = JiraPageState.decode(Data(#"{"tab":"watching","filter":{"status":"blocked","project":"ISD"}}"#.utf8))
        check(old?.tab == .watching && old?.filter.status == .blocked && old?.filter.project == "ISD" && old?.filter.sort == .updated && old?.filter.group == JiraGrouping.none, "old file")
        check(JiraPageState.decode(nil) == nil && JiraPageState.decode(Data("nope".utf8)) == nil, "bad file")
        check(JiraQuery.summary(.assigned, JiraFilter(project: "ISD, ACME", statusName: "Waiting", assignee: "unassigned"), people: [:]) == "ISD, ACME \u{00B7} Waiting \u{00B7} Unassigned", "name")
        check(JiraQuery.summary(.reported, JiraFilter(), people: [:]) == "Reported", "bare name")
    }),
]
