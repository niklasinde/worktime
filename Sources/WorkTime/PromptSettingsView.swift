import AppKit
import SwiftUI

/// Settings → Agent: the prompts WorkTime writes for its agents, each a Markdown file to edit.
struct PromptTemplatesSettings: View {
    @State private var editing: PromptTemplate?
    @State private var refresh = 0
    private let files = PromptFiles.current

    var body: some View {
        let path = (files.directory(.shared).path as NSString).abbreviatingWithTildeInPath
        SettingsSection("Prompts", footer: "The text WorkTime sends its agents, kept as Markdown files in \(path) and, for one workspace, in Workspaces/<name>/Prompts. "
                        + "A workspace\u{2019}s own file wins over the shared one. A change applies to the next prompt; agents already running keep what they were told.") {
            ForEach(Array(PromptTemplate.allCases.enumerated()), id: \.element) { index, template in
                if index > 0 { Divider().padding(.leading, 14) }
                row(template)
            }
            Divider().padding(.leading, 14)
            HStack {
                Spacer()
                Button("Open Folder") {
                    files.seed()
                    NSWorkspace.shared.open(files.directory(.shared))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .id(refresh)
        .sheet(item: $editing, onDismiss: { refresh += 1 }) { template in PromptEditor(template: template, files: files) }
    }

    private func row(_ template: PromptTemplate) -> some View {
        let changed = files.isChanged(template, scope: .shared) || WorkspaceStore.shared.workspaces.contains { files.isChanged(template, scope: .workspace($0.id)) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.title)
                    if changed { Text("edited").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    if files.isOutdated(template, scope: .shared) {
                        Text("newer built-in").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .help("The built-in text has changed since this file was written. Reset it to use the new text.")
                    }
                }
                Text(template.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Edit\u{2026}") { editing = template }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One template: its text for every workspace or for one, the placeholders it can use, and a preview filled in with sample values.
struct PromptEditor: View {
    let template: PromptTemplate
    let files: PromptFiles
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var workspaces = WorkspaceStore.shared
    @State private var scope = PromptScope.shared
    @State private var state: PromptEditorState
    @State private var draft: String
    @State private var showsPreview = false

    init(template: PromptTemplate, files: PromptFiles, showsPreview: Bool = false) {
        self.template = template
        self.files = files
        _showsPreview = State(initialValue: showsPreview)
        let initial = PromptEditorState(template: template, scope: .shared, files: files)
        _state = State(initialValue: initial)
        _draft = State(initialValue: initial.text)
    }

    private var problem: String? { state.problem(of: draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).font(.title3.weight(.semibold))
                Text(template.summary).font(.callout).foregroundStyle(.secondary)
            }
            if let warning = template.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Picker("For", selection: $scope) {
                    Text("Every workspace").tag(PromptScope.shared)
                    ForEach(workspaces.workspaces) { workspace in Text(workspace.name).tag(PromptScope.workspace(workspace.id)) }
                }
                .fixedSize()
                Text(state.sourceNote).font(.caption).foregroundStyle(.secondary)
                if state.isOutdated {
                    Text("The built-in text has changed since this file was written.").font(.caption).foregroundStyle(.orange)
                }
            }
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            if let problem {
                Label(problem, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            placeholderList
            DisclosureGroup("Preview with sample data", isExpanded: $showsPreview) {
                ScrollView {
                    Text(state.preview(of: draft, files: files))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            HStack {
                Button("Reset to Built-in") { reset() }
                Button("Reveal in Finder") { reveal() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
        .onChange(of: scope) { _, newScope in load(newScope) }
    }

    @ViewBuilder private var placeholderList: some View {
        if !template.placeholders.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Placeholders").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(template.placeholders.prefix(12), id: \.name) { placeholder in
                    HStack(spacing: 6) {
                        Text("{\(placeholder.name)}").font(.system(.caption, design: .monospaced))
                        Text(placeholder.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if template.placeholders.count > 12 {
                    Text("and \(template.placeholders.count - 12) more fields of the event, left empty when the event has none").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load(_ newScope: PromptScope) {
        state = PromptEditorState(template: template, scope: newScope, files: files)
        draft = state.text
    }

    private func save() {
        files.write(draft, template, scope: scope)
        dismiss()
    }

    private func reset() {
        files.reset(template, scope: scope)
        load(scope)
    }

    private func reveal() {
        files.seed()
        var url = files.url(template, scope: scope)
        if !FileManager.default.fileExists(atPath: url.path) { url = files.url(template, scope: .shared) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
