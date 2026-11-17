import Foundation

/// What the editor of a template shows for one scope: the text in effect there, where it comes from and what a save or a reset does.
struct PromptEditorState: Equatable {
    let template: PromptTemplate
    let scope: PromptScope
    var text: String
    var source: PromptFiles.Source
    var isOutdated: Bool

    init(template: PromptTemplate, scope: PromptScope, files: PromptFiles) {
        self.template = template
        self.scope = scope
        switch scope {
        case .shared:
            let resolved = files.resolve(template)
            text = resolved.text
            source = resolved.source
        case .workspace(let id):
            let resolved = files.resolve(template, workspace: id)
            text = resolved.text
            source = resolved.source
        }
        isOutdated = files.isOutdated(template, scope: scope)
    }

    /// The text can be saved: it is not empty and names no placeholder the template lacks.
    func problem(of draft: String) -> String? {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A template cannot be empty; reset it to go back to the built-in text." }
        let unknown = PromptTemplates.unknown(in: draft, for: template)
        guard !unknown.isEmpty else { return nil }
        return "Not a placeholder of this template: " + unknown.map { "{\($0)}" }.joined(separator: ", ")
    }

    /// The template filled in with sample values, for the preview. Its draft format comes from the same scope.
    func preview(of draft: String, files: PromptFiles) -> String {
        var values = PromptTemplates.sampleValues(for: template)
        if template != .reviewDraftFormat {
            switch scope {
            case .shared: values["draft_format"] = PromptTemplates.body(.reviewDraftFormat, files: files)
            case .workspace(let id): values["draft_format"] = PromptTemplates.body(.reviewDraftFormat, workspace: id, files: files)
            }
        }
        return PromptTemplates.render(draft, values)
    }

    /// What the scope line of the editor says.
    var sourceNote: String {
        switch (scope, source) {
        case (.shared, .builtIn): "Built-in text: no file has been written yet."
        case (.shared, _): "From the shared file."
        case (.workspace, .workspace): "This workspace has a file of its own."
        case (.workspace, .shared): "No file of its own: the shared one applies. Saving makes one for this workspace."
        case (.workspace, _): "No file of its own: the built-in text applies. Saving makes one for this workspace."
        }
    }
}
