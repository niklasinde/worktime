import SwiftUI

/// The calls a turn could not make, each with the fixes that would let it through, and Fix and continue to have the same session go on.
struct BlockedCard: View {
    let calls: [BlockedCall]
    let fixed: Set<String>
    let apply: (BlockedCall.Fix, BlockedCall) -> Void
    let fixAndContinue: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Blocked: \(calls.count) call\(calls.count == 1 ? "" : "s") could not run", systemImage: "exclamationmark.octagon")
                .font(.callout.weight(.medium))
            ForEach(calls) { call in row(call) }
            HStack {
                Button("Fix and continue", action: fixAndContinue).buttonStyle(.borderedProminent)
                    .help("Applies the fixes that save no rule, and has the same session go on")
                Button("Dismiss", action: dismiss).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.6)))
    }

    private func row(_ call: BlockedCall) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(AgentLogic.displayName(call.tool)).font(.callout.weight(.medium))
                Text(call.reason).font(.caption).foregroundStyle(.secondary)
            }
            if !call.summary.isEmpty {
                Text(call.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if fixed.contains(call.id) {
                Label("Fixed", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else if !call.fixes.isEmpty {
                HStack {
                    ForEach(call.fixes, id: \.label) { fix in
                        Button(fix.label) { apply(fix, call) }.controlSize(.small)
                    }
                }
            }
        }
    }
}
