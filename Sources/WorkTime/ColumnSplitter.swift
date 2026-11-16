import SwiftUI

/// The draggable line between a list and its page; dragging sets the list's stored width within what `GitHubLayout` allows.
struct ColumnSplitter: View {
    @Binding var width: Double
    let current: Double
    let total: Double
    @State private var dragStart: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle()).pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? current
                            dragStart = start
                            width = GitHubLayout.listWidth(start + drag.translation.width, in: total)
                        }
                        .onEnded { _ in dragStart = nil })
            }
    }
}
