import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func sandbox() -> PromptFiles {
    PromptFiles(folder: FileManager.default.temporaryDirectory.appendingPathComponent("worktime-prompt-test-\(UUID().uuidString)", isDirectory: true))
}

private func pull(_ number: Int, repo: String = "acme-com/orbit.api") -> LinkedPR {
    LinkedPR(url: "https://github.com/\(repo)/pull/\(number)", repo: repo, number: number)
}

private func routine(workspace: String = "work", ask: AutomationAsk? = nil, automation: Bool = true) -> Routine {
    Routine(id: "A1", name: "Reviews", prompt: "triage", workspace: workspace, schedule: RoutineSchedule(kind: .daily), created: now,
            trigger: automation ? AutomationTrigger(kind: .reviewRequested) : nil, followUp: AutomationFollowUp(notify: true, remind: true, ask: ask))
}

let promptTemplateTests: [(name: String, run: () throws -> Void)] = [
    ("prompt templates: a placeholder is a lower-case name in braces, and a JSON example is not one", {
        check(PromptTemplates.placeholders(in: "Review {pr_url} and {pr_url} then {answer}.") == ["pr_url", "answer"], "once each, in order")
        check(PromptTemplates.placeholders(in: #"{"pr": "x", "comments": [{"file": "a"}]} {} { pr } {Pr} {1st} {a-b}"#).isEmpty, "none of these")
        check(PromptTemplates.placeholders(in: "{pr_count}{pull_requests}") == ["pr_count", "pull_requests"], "next to each other")
        check(PromptTemplates.placeholders(in: "a { b {c} d").elementsEqual(["c"]), "an open brace before a placeholder")
    }),

    ("prompt templates: values fill the placeholders, others stay, and a value is not searched again", {
        let text = "Review {pr_url}.\n{draft_format}\nNotes: {answer} {unknown}"
        let out = PromptTemplates.render(text, ["pr_url": "U", "answer": "braces {pr_url} stay", "draft_format": #"{"pr": "x"}"#])
        check(out == "Review U.\n{\"pr\": \"x\"}\nNotes: braces {pr_url} stay {unknown}", out)
        check(PromptTemplates.render("no placeholders", ["a": "b"]) == "no placeholders", "unchanged")
        check(PromptTemplates.render("{a}{b}", ["a": "1", "b": "2"]) == "12", "adjacent")
        check(PromptTemplates.render("é {a} ü", ["a": "x"]) == "é x ü", "non-ASCII text around")
    }),

    ("prompt templates: every built-in names only placeholders its template offers", {
        for template in PromptTemplate.allCases {
            check(PromptTemplates.unknown(in: template.builtIn, for: template).isEmpty, "\(template.rawValue): \(PromptTemplates.unknown(in: template.builtIn, for: template))")
            check(!template.builtIn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !template.title.isEmpty && !template.summary.isEmpty, "\(template.rawValue) is described")
        }
        check(Set(PromptTemplate.allCases.map(\.fileName)).count == PromptTemplate.allCases.count, "file names differ")
        check(PromptTemplates.unknown(in: "{pr_url} {oops}", for: .reviewPR) == ["oops"], "an unknown one is found")
    }),

    ("prompt templates: the wording follows the number of pull requests", {
        let one = PromptTemplates.pullRequestValues(urls: ["u1"], lines: "L")
        check(one["pr_count"] == "1" && one["pull_requests"] == "pull request" && one["these_pull_requests"] == "this pull request", "\(one)")
        let three = PromptTemplates.pullRequestValues(urls: ["u1", "u2", "u3"], lines: "L")
        check(three["pr_count"] == "3" && three["pull_requests"] == "pull requests" && three["these_pull_requests"] == "these 3 pull requests", "\(three)")
        check(three["pr_urls"] == "- u1\n- u2\n- u3" && three["pr_list_with_checkouts"] == "L", "the addresses are bullets")
    }),

    ("prompt templates: a set of one is not 'these 1 pull requests', and the format sits on lines of its own", {
        let files = sandbox()
        let single = PullRequestSets.prompt([pull(1)], files: files)
        check(!single.contains("1 pull requests") && single.hasPrefix("Review https://github.com/acme-com/orbit.api/pull/1."), single)
        let several = PullRequestSets.prompt([pull(1), pull(2, repo: "acme-com/orbit.admin")], files: files)
        check(several.hasPrefix("Review these 2 pull requests as one change."), several)
        for text in [single, several] {
            check(text.contains("click:\n\n```worktime-review\n{\"pr\":") && text.contains("}\n```\n\nGet the sha"), "the block stands alone: \(text)")
            check(!text.contains("{draft_format}") && !text.contains("{pr_urls}"), "nothing is left unfilled")
            check(text.contains("(no checkout found)"), "each pull request is listed")
        }
        var topic = TopicAgent(id: "S1", name: "Review: two", folder: "/tmp/s1", created: now, pullRequests: [pull(1)])
        check(PullRequestSets.systemPrompt(topic, files: files).contains("on 1 pull request that belong together"), "the system prompt in the singular")
        topic.pullRequests = [pull(1), pull(2)]
        let system = PullRequestSets.systemPrompt(topic, files: files)
        check(system.contains("on 2 pull requests that belong together, as \u{201C}Review: two\u{201D}") && system.contains("working folder is /tmp/s1"), system)
    }),

    ("prompt templates: a workspace's file wins over the shared one, which wins over the built-in text, and an empty file counts as none", {
        let files = sandbox()
        let template = PromptTemplate.unattendedRun
        check(files.resolve(template, workspace: "work").source == .builtIn, "nothing written yet")
        files.write("Shared {name}", template, scope: .shared)
        check(files.resolve(template, workspace: "work") == ("Shared {name}", .shared) && files.resolve(template).source == .shared, "the shared file")
        files.write("Work's {name}", template, scope: .workspace("work"))
        check(files.resolve(template, workspace: "work") == ("Work's {name}", .workspace), "the workspace's own file")
        check(files.resolve(template, workspace: "reviews").source == .shared && files.resolve(template).text == "Shared {name}", "other workspaces keep the shared one")
        files.write("   \n", template, scope: .workspace("work"))
        check(files.resolve(template, workspace: "work").source == .shared, "an empty file is skipped")
        try? Data().write(to: files.url(template, scope: .shared))
        check(files.resolve(template, workspace: "work").source == .builtIn, "so is an empty shared one")
    }),

    ("prompt templates: seeding writes the files that are missing and never touches one that exists", {
        let files = sandbox()
        files.write("My own words {name}", .unattendedRun, scope: .shared)
        files.seed()
        for template in PromptTemplate.allCases { check(FileManager.default.fileExists(atPath: files.url(template, scope: .shared).path), "\(template.rawValue) seeded") }
        check(files.resolve(.unattendedRun).text == "My own words {name}", "the edited file is as it was")
        check(files.resolve(.automationRun).text == PromptTemplate.automationRun.builtIn.trimmingCharacters(in: .whitespacesAndNewlines), "a seeded file holds the built-in text")
        files.write("Edited", .automationRun, scope: .shared)
        files.seed()
        check(files.resolve(.automationRun).text == "Edited", "a second seeding changes nothing")
    }),

    ("prompt templates: reset puts the built-in text back in the shared file and removes a workspace's own", {
        let files = sandbox()
        files.write("Mine", .agentReport, scope: .shared)
        files.write("Theirs", .agentReport, scope: .workspace("work"))
        check(files.isChanged(.agentReport, scope: .shared) && files.isChanged(.agentReport, scope: .workspace("work")), "both differ")
        files.reset(.agentReport, scope: .workspace("work"))
        check(!FileManager.default.fileExists(atPath: files.url(.agentReport, scope: .workspace("work")).path) && files.resolve(.agentReport, workspace: "work").text == "Mine", "the workspace falls back")
        files.reset(.agentReport, scope: .shared)
        check(!files.isChanged(.agentReport, scope: .shared) && files.resolve(.agentReport).text == PromptTemplate.agentReport.builtIn.trimmingCharacters(in: .whitespacesAndNewlines), "the built-in text is back")
    }),

    ("prompt templates: a file has front matter that is left out of the text and read for its version", {
        let template = PromptTemplate.reviewSet
        let file = PromptTemplates.file(template, body: "Review {these_pull_requests}.\n")
        check(file.hasPrefix("---\ndescription: ") && file.contains("\nplaceholders: pr_count, pull_requests, these_pull_requests,") && file.contains("\nversion: 1\n---\n"), file)
        let parsed = PromptTemplates.parse(file)
        check(parsed.body == "Review {these_pull_requests}." && parsed.version == 1, "\(parsed)")
        let plain = PromptTemplates.parse("Just text.\r\nTwo lines.\n")
        check(plain.body == "Just text.\nTwo lines." && plain.version == nil, "a file without front matter is all text: \(plain)")
        check(PromptTemplates.parse("---\ndescription: x\n---\n").body.isEmpty, "front matter alone is empty")
        check(PromptTemplates.file(.agentActions, body: "x").contains("keep: ") && !PromptTemplates.file(.unattendedRun, body: "x").contains("keep: "), "a warning where the app reads the output")
        let files = sandbox()
        files.write("Old", .jiraAsk, scope: .shared)
        var old = try! String(contentsOf: files.url(.jiraAsk, scope: .shared), encoding: .utf8)
        old = old.replacingOccurrences(of: "version: 1", with: "version: 0")
        try! Data(old.utf8).write(to: files.url(.jiraAsk, scope: .shared))
        check(files.isOutdated(.jiraAsk, scope: .shared) && !files.isOutdated(.agentReport, scope: .shared), "an older file is noticed")
    }),

    ("prompt templates: the review draft format is shared by the prompts and follows the workspace", {
        let files = sandbox()
        files.write("OUR FORMAT", .reviewDraftFormat, scope: .workspace("reviews"))
        let own = PromptTemplates.render(.reviewPR, ["pr_url": "U", "pr_list_with_checkouts": "L"], workspace: "reviews", files: files)
        check(own.contains("OUR FORMAT") && !own.contains("worktime-review"), own)
        let other = PromptTemplates.render(.reviewPR, ["pr_url": "U", "pr_list_with_checkouts": "L"], workspace: "work", files: files)
        check(other.contains("```worktime-review") && !other.contains("OUR FORMAT"), "the built-in format elsewhere")
        check(AutomationAsks.defaultPrompt(for: .reviewRequested, workspace: "reviews", files: files).contains("OUR FORMAT"), "the review button")
        check(AutomationAsks.setPrompt(workspace: "reviews", files: files).contains("OUR FORMAT") && AutomationAsks.setPrompt(workspace: "work", files: files).contains("worktime-review"), "the set button")
        check(AutomationAsks.defaultPrompt(for: .jiraAssigned, files: files).hasPrefix("Work on {ticket} ({ticket_title}): {url}."), "the ticket button")
        check(ReviewDrafts.instructions.contains("```worktime-review") && ReviewDrafts.instructions.contains("click:\n\n```"), "the built-in constant")
    }),

    ("prompt templates: the button's prompt is the template with the event, the answer and the format filled in", {
        let files = sandbox()
        PromptFiles.current = files
        defer { PromptFiles.current = PromptFiles(folder: files.folder.appendingPathComponent("after")) }
        files.write("Look at {pr_url} ({pr_title}).\n{draft_format}\nFirst look: {answer} / {recommendation}", .reviewPRAsk, scope: .workspace("work"))
        let ask = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer")
        let event = AutomationEvent(id: "e", kind: .reviewRequested, title: "t", place: "p", text: "x", fields: ["pr_url": "https://github.com/acme-com/orbit.api/pull/1", "pr_title": "Change"],
                                    pullRequest: "https://github.com/acme-com/orbit.api/pull/1", link: nil, date: now)
        let run = RoutineRun(started: now, finished: now, status: .done, summary: "Small change.\nRecommendation: review it - touches money")
        let notice = AutomationAsks.notice(for: routine(ask: ask), event: event, run: run, ask: ask, reminder: nil)
        check(notice?.prompt.hasPrefix("Look at https://github.com/acme-com/orbit.api/pull/1 (Change).\n") == true, notice?.prompt ?? "nil")
        check(notice?.prompt.contains("```worktime-review") == true && notice?.prompt.contains("touches money") == true && notice?.prompt.contains("Small change.") == true, "filled in")
        let others = AutomationAsks.notice(for: routine(workspace: "reviews", ask: ask), event: event, run: run, ask: ask, reminder: nil)
        check(others?.prompt.hasPrefix("Review https://github.com/acme-com/orbit.api/pull/1. Read the diff") == true, "another workspace keeps the built-in text")
        let mine = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer", prompt: "Mine:\n{draft_format}")
        let own = AutomationAsks.notice(for: routine(ask: mine), event: event, run: run, ask: mine, reminder: nil)
        check(own?.prompt.hasPrefix("Mine:\n") == true && own?.prompt.contains("```worktime-review") == true, "a prompt written in the automation may use the format too")
    }),

    ("prompt templates: the run notes come from their templates, in the routine's workspace", {
        let files = sandbox()
        PromptFiles.current = files
        defer { PromptFiles.current = PromptFiles(folder: files.folder.appendingPathComponent("after")) }
        let ask = AutomationAsk(yes: "Review it", no: "Skip", agent: "assistant:work:reviewer")
        let plain = Routines.systemPrompt(routine(automation: false), base: nil)
        check(plain.hasPrefix("This is the scheduled routine \u{201C}Reviews\u{201D}, running on its own with nobody at the keyboard."), plain)
        let asked = Routines.systemPrompt(routine(ask: ask), base: "Base")
        check(asked.hasPrefix("Base\n\nThis is the automation \u{201C}Reviews\u{201D}") && asked.contains("(a pull request needs my review)") == false, asked)
        check(asked.contains("This run was started by an event (") && asked.contains(" The user is asked next, with the buttons \u{201C}Review it\u{201D} and \u{201C}Skip\u{201D}"), asked)
        check(asked.contains("Recommendation: review it or Recommendation: skip,"), asked)
        files.write("Quiet {kind} {name}.", .unattendedRun, scope: .workspace("work"))
        check(Routines.systemPrompt(routine(automation: false), base: nil) == "Quiet scheduled routine Reviews.", "the workspace's own wording")
        check(Routines.systemPrompt(routine(workspace: "reviews", automation: false), base: nil).hasPrefix("This is the scheduled routine"), "another workspace")
        files.write("Event: {event}.", .automationRun, scope: .shared)
        check(Automations.systemNote(routine()).hasPrefix("Event: "), "the shared wording")
    }),

    ("prompt templates: Main's note about reports follows its workspace", {
        let files = sandbox()
        let instructions = WorkspaceInstructionFiles(folder: files.folder, home: NSHomeDirectory())
        let work = Workspaces.defaults[0]
        let before = instructions.prompt(for: work, others: [])
        check(before.contains(AgentReports.mainNote), "the built-in note")
        files.write("TREAT REPORTS MY WAY", .mainReportNote, scope: .workspace("work"))
        let after = instructions.prompt(for: work, others: [])
        check(after.contains("TREAT REPORTS MY WAY") && !after.contains("never the user speaking"), "the workspace's note replaces it")
        check(instructions.prompt(for: Workspaces.defaults[1], others: []).contains(AgentReports.mainNote), "another workspace")
    }),

    ("prompt templates: the sidecar gets the three instruction texts of the agent's workspace", {
        let files = sandbox()
        let builtIn = PromptTemplates.agentInstructions(files: files)
        check(Set(builtIn.keys) == ["actions", "review", "report"], "\(builtIn.keys)")
        check(builtIn["actions"]?.contains("```worktime-action") == true && builtIn["review"]?.contains("```worktime-review") == true && builtIn["report"]?.contains("send_to_main") == true, "the built-in texts")
        files.write("Report my way.", .agentReport, scope: .workspace("work"))
        check(PromptTemplates.agentInstructions(workspace: "work", files: files)["report"] == "Report my way." && PromptTemplates.agentInstructions(workspace: "reviews", files: files)["report"] == builtIn["report"], "per workspace")
        let line = AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil, instructions: ["actions": "A", "review": "B", "report": "C"]).line
        check(line.contains(#""instructions":{"actions":"A","report":"C","review":"B"}"#), line)
        check(!AgentRequest.prompt(text: "hi", cwd: "/r", sessionID: nil).line.contains("instructions"), "none by default")
    }),

    ("prompt templates: the editor says where the text comes from and refuses what the template cannot fill in", {
        let files = sandbox()
        let shared = PromptEditorState(template: .reviewSet, scope: .shared, files: files)
        check(shared.source == .builtIn && shared.text == PromptTemplate.reviewSet.builtIn.trimmingCharacters(in: .whitespacesAndNewlines) && shared.sourceNote.hasPrefix("Built-in"), shared.sourceNote)
        check(shared.problem(of: shared.text) == nil, "the built-in text is fine")
        check(shared.problem(of: "  \n") != nil, "empty")
        check(shared.problem(of: "Review {these_pull_requests} {oops} {pr_url}")?.contains("{oops}") == true, "unknown")
        files.write("Shared", .reviewSet, scope: .shared)
        let own = PromptEditorState(template: .reviewSet, scope: .workspace("work"), files: files)
        check(own.source == .shared && own.text == "Shared" && own.sourceNote.contains("Saving makes one"), own.sourceNote)
        files.write("Own", .reviewSet, scope: .workspace("work"))
        check(PromptEditorState(template: .reviewSet, scope: .workspace("work"), files: files).source == .workspace, "its own file")
        let preview = shared.preview(of: shared.text, files: files)
        check(preview.hasPrefix("Review these 2 pull requests as one change.") && !preview.contains("{these_pull_requests}") && !preview.contains("{draft_format}"), preview)
        check(preview.contains("acme-com/orbit.api/pull/12"), "sample data")
        for template in PromptTemplate.allCases {
            let rendered = PromptEditorState(template: template, scope: .shared, files: files).preview(of: template.builtIn, files: files)
            check(PromptTemplates.placeholders(in: rendered).isEmpty, "\(template.rawValue) is filled in: \(PromptTemplates.placeholders(in: rendered))")
        }
    }),

    ("prompt templates: the pull request addresses of a Slack event are a list", {
        let message = SlackMessage(kind: .mention, teamID: "T1", channelID: "C1", place: "#reviews", author: "sam",
                                   text: "Please review https://github.com/acme-com/orbit.api/pull/12 and https://github.com/acme-com/orbit.admin/pull/7",
                                   ts: "1800000000.000100", permalink: nil)
        let event = Automations.slackEvent(message, link: nil)
        check(event.fields["pr_urls"] == "- https://github.com/acme-com/orbit.api/pull/12\n- https://github.com/acme-com/orbit.admin/pull/7", event.fields["pr_urls"] ?? "nil")
    }),
]
