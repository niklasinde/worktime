import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

extension Workspaces {
    static let sample = [
        Workspace(id: "work", name: "Work", symbol: "briefcase.fill", color: "blue", roots: ["~/git/acme"], githubOwners: ["acme-com"],
                  jiraProjects: ["ACME", "ISD", "QPB"], slack: "Acme", extraFiles: []),
        Workspace(id: "personal", name: "Personal", symbol: "person.fill", color: "green", roots: ["~/git/inde"], githubOwners: ["niklasinde"],
                  jiraProjects: [], slack: nil, extraFiles: []),
    ]
}
