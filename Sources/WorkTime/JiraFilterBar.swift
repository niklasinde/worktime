import AppKit
import SwiftUI

/// The filters above the Jira list: a chip for each project, menus for the assignee, the status and the rest, and the saved views.
struct JiraFilterBar: View {
    @ObservedObject var model: JiraPageModel
    @State private var findingPerson = false
    @State private var naming = false
    @State private var viewName = ""

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(model.projectChoices, id: \.self) { project in
                Button(project) { model.filter.project = JiraChoices.toggled(model.filter.project, project) }
                    .buttonStyle(NotchChipStyle(selected: JiraChoices.contains(model.filter.project, project)))
                    .help("Only \(project) tickets")
            }
            assigneeMenu
            statusMenu
            moreMenu
            viewsMenu
        }
    }

    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .frame(maxWidth: 220)
    }

    // MARK: Assignee

    private var assigneeMenu: some View {
        let filter = model.filter
        let title = filter.assignee.map { JiraAssignee.summary($0, people: model.people) } ?? (model.tab == .assigned ? "Me" : "Anyone")
        return Menu {
            assigneeItem("Me", token: JiraAssignee.me)
            assigneeItem("Unassigned", token: JiraAssignee.unassigned)
            assigneeItem("Anyone", token: JiraAssignee.anyone)
            let choices = model.assigneeChoices
            if !choices.isEmpty {
                Divider()
                ForEach(choices) { person in assigneeItem(person.name, token: JiraAssignee.token(for: person)) }
            }
            Divider()
            Button("Find Person\u{2026}") { findingPerson = true }
        } label: {
            menuLabel("Assignee: " + title)
        }
        .menuStyle(.button)
        .buttonStyle(NotchChipStyle(selected: filter.assignee != nil))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who the tickets are assigned to")
        .popover(isPresented: $findingPerson, arrowEdge: .bottom) {
            JiraPersonPicker(model: model, issueKey: nil) { person in
                model.remember([person])
                model.filter.assignee = JiraAssignee.toggled(model.filter.assignee, JiraAssignee.token(for: person))
                findingPerson = false
            }
        }
    }

    private func assigneeItem(_ title: String, token: String) -> some View {
        Toggle(title, isOn: Binding(get: { assigneeOn(token) }, set: { _ in toggleAssignee(token) }))
    }

    /// The Assigned tab without a choice is assigned to me, the others are open to anyone.
    private func assigneeOn(_ token: String) -> Bool {
        guard let assignee = model.filter.assignee else { return token == (model.tab == .assigned ? JiraAssignee.me : JiraAssignee.anyone) }
        return JiraChoices.contains(assignee, token)
    }

    private func toggleAssignee(_ token: String) {
        if model.filter.assignee == nil, assigneeOn(token) { return }
        model.filter.assignee = JiraAssignee.toggled(model.filter.assignee, token)
    }

    // MARK: Status

    private var statusMenu: some View {
        let chosen = JQLFilter.list(model.filter.statusName)
        return Menu {
            ForEach(model.options.statuses, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { JiraChoices.contains(model.filter.statusName, name) },
                                           set: { _ in model.filter.statusName = JiraChoices.toggled(model.filter.statusName, name) }))
            }
            Divider()
            Button("Any Status") { model.filter.statusName = nil }.disabled(chosen.isEmpty)
        } label: {
            menuLabel(chosen.isEmpty ? "Status" : chosen.count == 1 ? "Status: \(chosen[0])" : "Status \u{00B7} \(chosen.count)")
        }
        .menuStyle(.button)
        .buttonStyle(NotchChipStyle(selected: !chosen.isEmpty))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Only tickets in these statuses")
    }

    // MARK: More

    private var moreMenu: some View {
        let options = model.options, filter = model.filter
        let active = [filter.type, filter.priority].filter { $0 != nil }.count + (filter.sort == .updated ? 0 : 1) + (filter.group == .none ? 0 : 1)
        return Menu {
            choice("Type", $model.filter.type, options.types, all: "All types")
            choice("Priority", $model.filter.priority, options.priorities, all: "All priorities")
            Picker("Sort", selection: $model.filter.sort) { ForEach(JiraSort.allCases) { Text($0.title).tag($0) } }
            Picker("Group", selection: $model.filter.group) { ForEach(JiraGrouping.allCases) { Text($0.title).tag($0) } }
            Divider()
            Button("Open These in Jira") {
                model.site.flatMap { JiraTickets.navigatorURL(site: $0, jql: model.activeJQL ?? JiraTickets.jql(model.tab, model.filter)) }
                    .map { _ = NSWorkspace.shared.open($0) }
            }
            .disabled(model.site == nil)
            Button("Reset Filters") { model.filter = JiraFilter(query: model.filter.query) }.disabled(filter.withoutText == JiraFilter())
        } label: {
            menuLabel(active == 0 ? "More" : "More \u{00B7} \(active)")
        }
        .menuStyle(.button)
        .buttonStyle(NotchChipStyle(selected: active > 0))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Type, priority, sorting and grouping")
    }

    private func choice(_ title: String, _ selection: Binding<String?>, _ values: [String], all: String) -> some View {
        Picker(title, selection: selection) {
            Text(all).tag(String?.none)
            ForEach(values, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }

    // MARK: Views

    private var viewsMenu: some View {
        let current = model.currentView
        return Menu {
            ForEach(model.savedViews) { view in
                Toggle(view.name, isOn: Binding(get: { current == view }, set: { _ in model.apply(view) }))
            }
            if !model.savedViews.isEmpty { Divider() }
            Button("Save Current View\u{2026}") {
                viewName = model.suggestedViewName
                naming = true
            }
            if !model.savedViews.isEmpty {
                Menu("Delete View") {
                    ForEach(model.savedViews) { view in Button(view.name, role: .destructive) { model.deleteView(view) } }
                }
            }
        } label: {
            menuLabel(current?.name ?? "Views")
        }
        .menuStyle(.button)
        .buttonStyle(NotchChipStyle(selected: current != nil))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved combinations of tab and filters")
        .popover(isPresented: $naming, arrowEdge: .bottom) { namingForm(closing: $naming) }
    }

    private func namingForm(closing showing: Binding<Bool>) -> some View {
        let name = viewName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Save this view").font(.headline)
            TextField("Name", text: $viewName).textFieldStyle(.roundedBorder).frame(width: 260).onSubmit { save(name, closing: showing) }
            HStack {
                Spacer()
                Button("Cancel") { showing.wrappedValue = false }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name, closing: showing) }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(14)
    }

    private func save(_ name: String, closing showing: Binding<Bool>) {
        guard !name.isEmpty else { return }
        model.saveView(named: name)
        showing.wrappedValue = false
    }
}
