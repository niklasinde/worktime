import Foundation

/// A proposal waiting for the user's click, with the run it came from, so the saving can be worked out again once the script has run.
struct PendingProposal: Codable, Equatable, Sendable {
    var proposal: DeterminismProposal
    var digest: RunDigest
    var created: Date
}

/// The scripts of the routines, one folder per routine: `script.v1.json`, `script.v2.json` and so on, never overwritten, and the
/// proposal that waits for the user's click.
struct RoutineScriptFiles: Sendable {
    var root: URL = AppPaths.routineScripts

    private static let proposalName = "proposal.json"

    func folder(_ routine: String) -> URL { root.appendingPathComponent(routine, isDirectory: true) }

    private func file(_ routine: String, version: Int) -> URL { folder(routine).appendingPathComponent("script.v\(version).json") }

    func versions(_ routine: String) -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(routine).path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("script.v"), name.hasSuffix(".json") else { return nil }
            return Int(name.dropFirst("script.v".count).dropLast(".json".count))
        }.sorted()
    }

    func load(_ routine: String, version: Int) -> RoutineScript? {
        guard let data = try? Data(contentsOf: file(routine, version: version)) else { return nil }
        return try? JSONDecoder().decode(RoutineScript.self, from: data)
    }

    /// Saves the script as the next version and returns its number.
    @discardableResult
    func save(_ script: RoutineScript, for routine: String) throws -> Int {
        let version = (versions(routine).last ?? 0) + 1
        try FileManager.default.createDirectory(at: folder(routine), withIntermediateDirectories: true)
        try Data(RoutineScripts.encode(script).utf8).write(to: file(routine, version: version), options: .atomic)
        return version
    }

    func pending(for routine: String) -> PendingProposal? {
        (try? Data(contentsOf: folder(routine).appendingPathComponent(Self.proposalName))).flatMap { AgentInbox.decode(PendingProposal.self, from: $0) }
    }

    func savePending(_ pending: PendingProposal, for routine: String) {
        try? FileManager.default.createDirectory(at: folder(routine), withIntermediateDirectories: true)
        try? AgentInbox.encode(pending).write(to: folder(routine).appendingPathComponent(Self.proposalName), options: .atomic)
    }

    func clearPending(for routine: String) {
        try? FileManager.default.removeItem(at: folder(routine).appendingPathComponent(Self.proposalName))
    }

    func delete(_ routine: String) { try? FileManager.default.removeItem(at: folder(routine)) }
}
