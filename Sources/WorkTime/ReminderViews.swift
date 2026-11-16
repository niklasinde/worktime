import SwiftUI

/// What a reminder is about, as a small chip that opens it.
struct SourceChip: View {
    let source: ReminderSource
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: source.icon).font(.system(size: 9))
                Text(source.label).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open \(source.label)")
    }
}

/// "Remind Me About This" for a context menu: the times to offer, then a reminder that links back to `source`.
struct RemindMeMenu: View {
    let title: String
    let source: ReminderSource

    var body: some View {
        Menu("Remind Me About This") {
            ForEach(ReminderPreset.allCases, id: \.self) { preset in
                Button(preset.title) { TodoModel.shared.remind(title: title, source: source, preset: preset) }
            }
        }
    }
}
