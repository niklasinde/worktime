import SwiftUI

/// The form behind New Ticket: the project and type come from Jira's create metadata, and what a type requires beyond a summary
/// is asked for here.
@MainActor
final class JiraCreateModel: ObservableObject {
    let draft: JiraCreateDraft
    let page: JiraPageModel
    @Published var project: String { didSet { if project != oldValue { loadTypes() } } }
    @Published var typeID: String? { didSet { if typeID != oldValue { loadForm() } } }
    @Published var summary: String
    @Published var description: String
    @Published var assignToMe = true
    @Published var values: [String: [String]] = [:]
    @Published private(set) var types: [JiraIssueType] = []
    @Published private(set) var form = JiraCreateForm()
    @Published private(set) var loading = false
    @Published private(set) var creating = false
    @Published private(set) var error: JiraError?
    private var loadTask: Task<Void, Never>?

    init(draft: JiraCreateDraft, page: JiraPageModel) {
        self.draft = draft
        self.page = page
        summary = draft.summary
        description = draft.description
        project = draft.project ?? JQLFilter.list(page.filter.project).first?.uppercased() ?? page.projectChoices.first ?? ""
        loadTypes()
    }

    var type: JiraIssueType? { types.first { $0.id == typeID } }

    var canCreate: Bool { type != nil && !loading && !creating && JiraCreate.canCreate(summary: summary, form: form, values: values) }

    private func loadTypes() {
        loadTask?.cancel()
        types = []
        typeID = nil
        form = JiraCreateForm()
        values = [:]
        guard !project.isEmpty else { return }
        loading = true
        error = nil
        let project = project
        loadTask = Task {
            let result = await page.issueTypes(in: project)
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let list):
                types = list
                typeID = JiraCreate.defaultType(among: list)?.id
            case .failure(let failure): error = failure
            }
        }
    }

    private func loadForm() {
        guard let typeID else { return }
        loadTask?.cancel()
        form = JiraCreateForm()
        values = [:]
        loading = true
        error = nil
        let project = project
        loadTask = Task {
            let result = await page.createForm(in: project, type: typeID)
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let found): form = found
            case .failure(let failure): error = failure
            }
        }
    }

    func create() {
        guard canCreate, let type else { return }
        creating = true
        error = nil
        Task {
            let assignee = assignToMe ? await page.currentUser()?.id : nil
            let body = JiraCreate.body(project: project, type: type, summary: summary, description: description, assignee: assignee,
                                       form: form, values: values)
            let result = await page.createTicket(body, summary: summary, from: draft)
            creating = false
            if case .failure(let failure) = result { error = failure }
        }
    }
}

struct JiraNewTicketView: View {
    @StateObject private var model: JiraCreateModel
    let page: JiraPageModel

    init(draft: JiraCreateDraft, page: JiraPageModel) {
        self.page = page
        _model = StateObject(wrappedValue: JiraCreateModel(draft: draft, page: page))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New ticket").font(.headline)
            HStack(spacing: 10) {
                Picker("Project", selection: $model.project) {
                    ForEach(page.projectChoices, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Picker("Type", selection: $model.typeID) {
                    ForEach(model.types) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                .disabled(model.types.isEmpty)
                if model.loading { ProgressView().controlSize(.small) }
            }
            TextField("Summary", text: $model.summary).textFieldStyle(.roundedBorder)
            TextEditor(text: $model.description)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 220)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            if model.form.available.contains("assignee") { Toggle("Assign to me", isOn: $model.assignToMe).toggleStyle(.checkbox) }
            ForEach(model.form.fields) { JiraFieldView(field: $0, values: $model.values) }
            if model.form.needsJira {
                Text("This type needs a field this app cannot fill in. Make the ticket in Jira.").font(.caption).foregroundStyle(.orange)
            }
            if let error = model.error { Text(error.message).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Creates the ticket in Jira as you.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if model.creating { ProgressView().controlSize(.small) }
                Button("Cancel") { page.newTicket = nil }.keyboardShortcut(.cancelAction)
                Button("Create", action: model.create).keyboardShortcut(.return, modifiers: .command).disabled(!model.canCreate)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
