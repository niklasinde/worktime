import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private let projects: Set<String> = ["ACME", "ORB"]

private func pr(_ number: Int, repo: String = "acme-com/orbit.api") -> SessionRef { .pullRequest(repo: repo, number: number) }

private func tool(_ id: String, _ summary: String, detail: String = "", result: String? = nil) -> AgentItem {
    AgentItem(id: id, kind: .tool(name: "Bash", summary: summary, detail: detail, result: result, isError: false, auto: true))
}

private func said(_ id: String, _ text: String, streaming: Bool = false) -> AgentItem {
    AgentItem(id: id, kind: .text(text), streaming: streaming)
}

private final class ScanResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (SessionLinks, Bool)?

    func set(_ value: SessionLinks, main: Bool) { lock.withLock { stored = (value, main) } }
    func get() -> (SessionLinks, Bool)? { lock.withLock { stored } }
}

let sessionLinksTests: [(name: String, run: () throws -> Void)] = [
    ("session links: tickets and pull requests are found in order, once each", {
        let found = SessionLinks.references(in: "See ACME-12 and https://github.com/acme-com/orbit.api/pull/7, then ACME-12 again, ORB-3 and acme-com/orbit.web#9", projects: projects)
        check(found == [.jira("ACME-12"), pr(7), .jira("ORB-3"), pr(9, repo: "acme-com/orbit.web")], "\(found)")
    }),
    ("session links: only the configured projects count as tickets", {
        let text = "UTF-8 and SHA-256 and ACME-5 and PROJ-1"
        check(SessionLinks.references(in: text, projects: projects) == [.jira("ACME-5")], "configured")
        check(SessionLinks.references(in: text, projects: []).isEmpty, "none configured")
    }),
    ("session links: a ticket in a branch name or a browse link is found, a longer word is not", {
        check(SessionLinks.references(in: "NI/ACME-8962-add-export", projects: projects) == [.jira("ACME-8962")], "branch")
        check(SessionLinks.references(in: "https://acme.atlassian.net/browse/ORB-40?x=1", projects: projects) == [.jira("ORB-40")], "browse")
        check(SessionLinks.references(in: "XACME-4 ACME-4x ACME-04 acme-4", projects: projects).isEmpty, "not tickets")
    }),
    ("session links: a pull request number alone is not a link, and the url may be in any case", {
        check(SessionLinks.references(in: "fixed in #42", projects: projects).isEmpty, "bare number")
        check(SessionLinks.references(in: "HTTPS://GitHub.com/Acme-Com/Orbit.Api/pull/3", projects: projects).count == 1, "case")
    }),
    ("session links: what a tool was asked and answered counts, a streaming message waits until it is complete", {
        var links = SessionLinks()
        let items = [tool("t1", "gh pr view 7", detail: "gh pr view https://github.com/acme-com/orbit.api/pull/7", result: "title: ACME-12 Export"),
                     said("a1", "Looking at ORB-3", streaming: true)]
        check(links.update(items, projects: projects), "changed")
        check(Set(links.recent) == [pr(7), .jira("ACME-12")], "\(links.recent)")
        var done = items
        done[1] = said("a1", "Looking at ORB-3")
        check(links.update(done, projects: projects), "complete now")
        check(links.recent.first == .jira("ORB-3"), "\(links.recent)")
    }),
    ("session links: an item is read once, and again only when it has changed", {
        var links = SessionLinks()
        let items = [said("a1", "ACME-1 and ACME-2")]
        check(links.update(items, projects: projects), "first read")
        let before = links
        check(!links.update(items, projects: projects), "nothing new")
        check(links == before, "unchanged state")
        check(links.update([said("a1", "ACME-1 and ACME-2 and ACME-3")], projects: projects), "grew")
        check(links.recent.contains(.jira("ACME-3")), "found")
    }),
    ("session links: an irrelevant tool answer is remembered as scanned", {
        var links = SessionLinks()
        let items = [tool("t1", "find files", result: String(repeating: "ordinary output\n", count: 4_000))]
        check(links.update(items, projects: projects), "the scan is saved")
        let before = links
        check(!links.update(items, projects: projects), "not parsed again")
        check(links == before, "unchanged state")
    }),
    ("session links: a ticket mentioned again moves to the front, and within one message the first named comes first", {
        var links = SessionLinks()
        links.update([said("a1", "ACME-1 ACME-2"), said("a2", "ORB-3")], projects: projects)
        check(links.recent == [.jira("ORB-3"), .jira("ACME-1"), .jira("ACME-2")], "\(links.recent)")
        links.update([said("a1", "ACME-1 ACME-2"), said("a2", "ORB-3"), said("a3", "back to ACME-1")], projects: projects)
        check(links.recent.first == .jira("ACME-1"), "\(links.recent)")
    }),
    ("session links: what the session was made for comes first, then by recency, once each and at most the limit", {
        var links = SessionLinks()
        links.update([said("a1", "ACME-1 ACME-2 ACME-3")], projects: projects)
        let ordered = links.ordered(pinned: [.jira("ACME-1"), pr(7)])
        check(ordered == [.jira("ACME-1"), pr(7), .jira("ACME-2"), .jira("ACME-3")], "\(ordered)")
        let many = (1...20).map { "ACME-\($0)" }.joined(separator: " ")
        var big = SessionLinks()
        big.update([said("a1", many)], projects: projects)
        check(big.ordered(pinned: []).count == SessionLinks.limit, "capped")
        check(big.total(pinned: [pr(1)]) == 21, "total \(big.total(pinned: [pr(1)]))")
    }),
    ("session links: a branch name is noted like a mention", {
        var links = SessionLinks()
        check(links.note(SessionLinks.references(in: "NI/ORB-77-fix", projects: projects)), "noted")
        check(links.recent == [.jira("ORB-77")], "\(links.recent)")
        check(!links.note([]), "nothing")
    }),
    ("session links: the projects are the configured ones and the session's own ticket's", {
        check(SessionProjects.set(configured: ["acme"], pinned: [.jira("ORB-1"), pr(2)]) == ["ACME", "ORB"], "set")
    }),
    ("session links: five rows show first, Show more opens the rest", {
        let refs = (1...9).map { SessionRef.jira("ACME-\($0)") }
        check(SessionLinkRows.visible(refs, expanded: false).count == 5, "collapsed")
        check(SessionLinkRows.hidden(refs, expanded: false) == 4, "hidden")
        check(SessionLinkRows.visible(refs, expanded: true).count == 9 && SessionLinkRows.hidden(refs, expanded: true) == 0, "expanded")
        check(SessionLinkRows.hidden(Array(refs.prefix(3)), expanded: false) == 0, "short list")
    }),
    ("session links: Related starts hidden and loading begins only when it is opened", {
        var state = SessionRelatedState()
        check(!state.visible && !state.loading, "hidden by default")
        let generation = state.open()
        check(state.visible && state.loading, "opening starts loading")
        check(state.finish(generation) && state.visible && !state.loading, "current scan finishes")
        state.close()
        check(!state.visible && !state.loading, "closing hides it")
        check(!state.finish(generation), "a closed scan cannot publish")
    }),
    ("session links: Related scans only the last twenty completed text and tool items", {
        var items = (0..<25).map { said("text-\($0)", "ACME-\($0 + 1)") }
        items.append(AgentItem(id: "status", kind: .status("ACME-90")))
        items.append(said("streaming", "ACME-91", streaming: true))
        items.append(tool("tool", "check", result: "ACME-92"))
        let inputs = SessionRelatedScan.inputs(from: items)
        check(inputs.count == 20, "bounded to \(inputs.count)")
        check(inputs.map(\.id) == (6..<25).map { "text-\($0)" } + ["tool"], "keeps the newest eligible items in order")
        let links = SessionRelatedScan.links(from: inputs, projects: projects)
        check(links.recent.first == .jira("ACME-92"), "newest result first")
        check(!links.recent.contains(.jira("ACME-6")) && links.recent.contains(.jira("ACME-7")), "older text was not scanned")
        check(!links.recent.contains(.jira("ACME-90")) && !links.recent.contains(.jira("ACME-91")), "non-text and streaming items were ignored")
    }),
    ("session links: the bounded Related scan is safe to run off the main thread", {
        let inputs = SessionRelatedScan.inputs(from: [said("a", "ACME-1"), said("b", "ORB-2")])
        let result = ScanResult()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            result.set(SessionRelatedScan.links(from: inputs, projects: projects), main: Thread.isMainThread)
            done.signal()
        }
        check(done.wait(timeout: .now() + 2) == .success, "scan completed")
        let scanned = result.get()
        check(scanned?.1 == false, "ran off main")
        check(scanned?.0.recent == [.jira("ORB-2"), .jira("ACME-1")], "ordering \(String(describing: scanned?.0.recent))")
    }),
    ("session links: very long output is read only up to the limit", {
        let long = String(repeating: "x", count: SessionLinks.textLimit) + " ACME-9"
        check(SessionLinks.references(in: long, projects: projects).isEmpty, "past the limit")
    }),
]
