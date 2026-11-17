import SwiftUI

struct DeterminismTarget: Identifiable {
    let id: String
}

/// The Make Deterministic sheet: the agent's proposal to do part of a routine with a script, or the script the routine runs now. Nothing
/// is saved until Save; the script and the shorter prompt can be edited first.
struct DeterminismSheet: View {
    enum Choice: String, CaseIterable, Identifiable {
        case script, hybrid

        var id: String { rawValue }
        var title: String { self == .script ? "Script only" : "Script, then a shorter prompt" }
    }

    let routineKey: String
    let done: () -> Void
    @ObservedObject private var store = RoutineStore.shared
    @State private var choice = Choice.hybrid
    @State private var scriptText = ""
    @State private var promptText = ""
    @State private var filled = false
    @State private var tried: ScriptResult?
    @State private var trying = false
    @State private var problem: String?

    private var routine: Routine? { store.routine(routineKey) }
    private var pending: PendingProposal? { store.pendingProposal(routineKey) }
    private var plan: DeterministicPlan? { routine?.determinism }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan == nil ? "Make \u{201C}\(routine?.name ?? "")\u{201D} deterministic" : "Script of \u{201C}\(routine?.name ?? "")\u{201D}").font(.headline)
            Text("The parts of a run that only fetch and format data can run as a script that calls read-only tools, so the model only does the judgement. "
                 + "A script can never post, approve, merge or send, and when it fails the agent does the run.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
            buttons
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { start() }
        .onChange(of: pending) { _, _ in fill() }
    }

    @ViewBuilder private var content: some View {
        if let analysis = store.analyses[routineKey] {
            switch analysis {
            case .analyzing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at the last run\u{2026}").foregroundStyle(.secondary) }
            case .failed(let message):
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } else if filled {
            editor
        } else {
            Text("There is no run to look at yet.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let proposal = pending?.proposal {
                Text(proposal.summary).fixedSize(horizontal: false, vertical: true)
                if !proposal.replaces.isEmpty { list("The script does", proposal.replaces) }
                if !proposal.keeps.isEmpty { list("The model still does", proposal.keeps) }
            } else if let plan {
                Text(planText(plan)).font(.callout).foregroundStyle(.secondary)
            }
            Picker("Mode", selection: $choice) { ForEach(Choice.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text("Script").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $scriptText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 190)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            if choice == .hybrid {
                Text("Prompt for the model, with \(Determinism.dataPlaceholder) where the script's output goes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextEditor(text: $promptText)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            }
            HStack {
                Button(trying ? "Trying\u{2026}" : "Try the script", action: tryScript).disabled(trying)
                if let saving { Text(saving).font(.caption).foregroundStyle(.secondary) }
            }
            if let tried { result(tried) }
        }
    }

    private func list(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { Text("\u{2022} \($0)").font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func result(_ result: ScriptResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure = result.failure {
                Label(failure, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(result.steps.count) steps, \(result.rawCharacters) characters fetched, \(result.output.count) in the output").font(.caption).foregroundStyle(.secondary)
            }
            if !result.output.isEmpty {
                ScrollView { Text(String(result.output.prefix(2000))).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 110)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            }
        }
    }

    private var buttons: some View {
        HStack {
            if plan != nil { Button("Revert to AI", role: .destructive) { store.revertToAI(routineKey); done() } }
            if pending != nil { Button("Dismiss") { store.dismissProposal(routineKey); done() } }
            Spacer()
            Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            if filled { Button("Save", action: save).keyboardShortcut(.defaultAction) }
        }
    }

    private var saving: String? {
        let mode: DeterministicPlan.Mode = choice == .script ? .script : .hybrid
        if let digest = pending?.digest {
            let tokens = Determinism.estimatedTokens(mode: mode, digest: digest, outputCharacters: tried?.output.count ?? digest.resultCharacters / 4)
            return "About \(Determinism.savedText(tokens)) tokens saved per run"
        }
        return plan.map { "About \(Determinism.savedText($0.savedTokens)) tokens saved per run" }
    }

    private func planText(_ plan: DeterministicPlan) -> String {
        var text = "Version \(plan.version), \(plan.mode == .script ? "script only" : "script then a shorter prompt"). Saved about \(Determinism.savedText(plan.savedTotal)) tokens so far."
        if plan.needsRecompile { text += " It needs recompiling: \(plan.reason ?? "it failed")." }
        return text
    }

    private func start() {
        fill()
        if !filled, store.analyses[routineKey] == nil { store.analyze(routineKey) }
    }

    private func fill() {
        if let proposal = pending?.proposal, let script = proposal.script {
            scriptText = RoutineScripts.encode(script)
            promptText = proposal.prompt ?? ""
            choice = proposal.mode == .script ? .script : .hybrid
            filled = true
        } else if let routine, let plan, !filled {
            scriptText = store.scriptSource(routine) ?? ""
            promptText = plan.prompt ?? ""
            choice = plan.mode == .script ? .script : .hybrid
            filled = true
        }
    }

    private func tryScript() {
        problem = nil
        switch RoutineScripts.decode(scriptText) {
        case .failure(let error): problem = error.message
        case .success(let script):
            if let message = RoutineScripts.problem(script, fields: Set(routine?.trigger?.kind.fields ?? [])) { return problem = message }
            trying = true
            let context = routine.flatMap(store.lastEvent)?.fields ?? [:]
            Task {
                tried = await RoutineScriptRunner.run(script, context: context)
                trying = false
            }
        }
    }

    private func save() {
        problem = nil
        switch RoutineScripts.decode(scriptText) {
        case .failure(let error): problem = error.message
        case .success(let script):
            let proposal = DeterminismProposal(mode: choice == .script ? .script : .hybrid, summary: pending?.proposal.summary ?? "", script: script,
                                               prompt: choice == .hybrid ? promptText : nil)
            if let error = store.compile(routineKey, proposal: proposal, digest: pending?.digest, outputCharacters: tried?.output.count) { problem = error.message } else { done() }
        }
    }
}
