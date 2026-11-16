import AppKit
import SwiftUI

/// A text field that grows with its text up to `maxLines`, then scrolls. Return sends and Shift+Return starts a new line.
struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    var maxLines = 6
    var attach: (([AgentImageSource]) -> Void)?
    var problem: ((String) -> Void)?
    let send: () -> Void

    static let inset = NSSize(width: 0, height: 4)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.attach = { [weak coordinator = context.coordinator] in coordinator?.parent.attach?($0) }
        textView.problem = { [weak coordinator = context.coordinator] in coordinator?.parent.problem?($0) }
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, .pdf] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = Self.inset
        textView.textContainer?.widthTracksTextView = true
        let scroll = ComposerScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.updateHeight() }
        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        let replaced = textView.string != text
        if replaced { textView.string = text }
        context.coordinator.updateHeight(reveal: replaced ? .top : nil)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        weak var textView: NSTextView?

        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            parent.text = textView?.string ?? ""
            updateHeight(reveal: .caret)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.send()
            }
            return true
        }

        enum Reveal { case top, caret }

        /// The text's height at the field's current width, between one line and `maxLines`. Text put in from outside, like a
        /// pre-filled prompt, is shown from its first line; typing keeps the caret in view.
        func updateHeight(reveal target: Reveal? = nil) {
            guard let textView, let container = textView.textContainer, let layout = textView.layoutManager,
                  let font = textView.font, textView.bounds.width > 0 else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: font)
            let padding = ChatComposer.inset.height * 2
            let height = ceil(min(max(layout.usedRect(for: container).height, line), line * CGFloat(parent.maxLines)) + padding)
            let reveal = {
                switch target {
                case .top: textView.scroll(.zero)
                case .caret: textView.scrollRangeToVisible(textView.selectedRange())
                case nil: break
                }
            }
            guard abs(parent.height - height) > 0.5 else { return reveal() }
            DispatchQueue.main.async {
                self.parent.height = height
                reveal()
            }
        }
    }
}

/// Tells the composer when its width changes, since the wrapped text's height depends on it.
private final class ComposerScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func tile() {
        super.tile()
        guard abs(contentSize.width - lastWidth) > 0.5 else { return }
        lastWidth = contentSize.width
        documentView?.frame.size.width = contentSize.width
        onWidthChange?()
    }
}

private final class PlaceholderTextView: NSTextView {
    var placeholder = ""
    var attach: (([AgentImageSource]) -> Void)?
    var problem: ((String) -> Void)?

    /// Takes a paste or drop that carries pictures; false leaves it to the text field.
    private func take(_ board: NSPasteboard) -> Bool {
        guard let attach else { return false }
        switch AgentPasteboard.read(board) {
        case .text: return false
        case .images(let sources): attach(sources)
        case .promised(let receivers): receive(receivers, attach: attach)
        case .unreadable: problem?(AgentImages.unreadable)
        }
        return true
    }

    private func receive(_ receivers: [NSFilePromiseReceiver], attach: @escaping ([AgentImageSource]) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkTimePaste-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { [weak self] url, error in
                if error == nil, AgentImages.isImageFile(url) { attach([.file(url)]) } else { self?.problem?(AgentImages.unreadable) }
            }
        }
    }

    override func paste(_ sender: Any?) { if !take(.general) { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { if !take(.general) { super.pasteAsPlainText(sender) } }
    override func pasteAsRichText(_ sender: Any?) { if !take(.general) { super.pasteAsRichText(sender) } }

    /// ⌘V reaches the field before the Edit menu, whose Paste is greyed out while the clipboard holds only a picture.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        if command, event.charactersIgnoringModifiers == "v", window?.firstResponder === self, take(.general) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        attach == nil ? super.readablePasteboardTypes : super.readablePasteboardTypes + AgentPasteboard.imageTypes
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if attach != nil, item.action == #selector(NSText.paste(_:)), AgentPasteboard.hasPicture(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard attach != nil, case .text = AgentPasteboard.read(sender.draggingPasteboard) else { return attach == nil ? super.draggingEntered(sender) : .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        take(sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
                         withAttributes: attributes)
    }

    override var string: String {
        didSet { needsDisplay = true }
    }
}
