import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let prURL = "https://github.com/acme-com/api/pull/1234"

private func state(_ title: String, pr: String? = nil, jira: String? = nil, prompt: String? = nil, result: String? = nil) -> AgentState {
    var state = AgentState(key: UUID().uuidString, title: title, prURL: pr, status: .idle)
    state.jiraKey = jira
    state.lastPrompt = prompt
    state.lastResult = result
    return state
}

private func routine(_ name: String, prompt: String = "", summary: String? = nil) -> Routine {
    var routine = Routine(id: UUID().uuidString, name: name, prompt: prompt, workspace: "work", schedule: .every(minutes: 60), created: Date())
    routine.lastRun = RoutineRun(started: Date(), status: .done, summary: summary)
    return routine
}

let agentSearchTests: [(name: String, run: () throws -> Void)] = [
    ("agent search: a blank query is not a search and keeps everything", {
        let states = [state("one"), state("two")]
        check(!AgentSearch.isActive("   "), "blank")
        check(AgentSearch.filter(states, query: " ").count == 2, "all kept")
    }),
    ("agent search: every word has to match, in any case, in any of the fields", {
        let agent = state("Fix login", jira: "ACME-12", result: "Deployed to staging")
        check(AgentSearch.filter([agent], query: "acme-12 STAGING").count == 1, "key and result")
        check(AgentSearch.filter([agent], query: "login prod").isEmpty, "one word missing")
    }),
    ("agent search: a pull request is found by number, repo#number and its title", {
        let agent = state("api#1234", pr: prURL)
        check(AgentSearch.filter([agent], query: "1234").count == 1, "number")
        check(AgentSearch.filter([agent], query: "api#1234").count == 1, "short reference")
        check(AgentSearch.filter([agent], query: "rate limit").isEmpty, "title unknown")
        check(AgentSearch.filter([agent], query: "rate limit", titles: [prURL: "Add rate limiting"]).count == 1, "title")
    }),
    ("agent search: the last prompt and result are searched", {
        let agent = state("Main", prompt: "summarise the invoices", result: "three overdue")
        check(AgentSearch.filter([agent], query: "invoices").count == 1, "prompt")
        check(AgentSearch.filter([agent], query: "overdue").count == 1, "result")
    }),
    ("agent search: routines and automations are found by name, prompt and last summary", {
        let routines = [routine("Morning sweep", prompt: "Check my pull requests", summary: "two need review"), routine("Nightly")]
        check(AgentSearch.filter(routines, query: "sweep").count == 1, "name")
        check(AgentSearch.filter(routines, query: "pull requests").count == 1, "prompt")
        check(AgentSearch.filter(routines, query: "need review").count == 1, "summary")
        check(AgentSearch.filter(routines, query: "zzz").isEmpty, "none")
    }),
    ("agent search: opening shows the box and asks for focus again each time, closing clears the query", {
        var field = AgentSearchField()
        field.open()
        field.query = "api"
        field.open()
        check(field.isOpen && field.focusTick == 2 && field.query == "api", "open twice keeps the query")
        field.close()
        check(!field.isOpen && field.query.isEmpty, "closed and cleared")
    }),
]
