import AppKit

/// What a paste or drop on the agent composer carries: pictures to attach, pictures that could not be read, files still to be
/// delivered, or just text for the text field to handle.
enum AgentPasteboard {
    enum Content {
        case text
        case images([AgentImageSource])
        case promised([NSFilePromiseReceiver])
        case unreadable
    }

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .pdf, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("com.apple.pict"),
    ]

    static func read(_ board: NSPasteboard) -> Content {
        let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let promises = (board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        if urls.isEmpty, !promises.isEmpty { return .promised(promises) }
        let data = urls.isEmpty ? imageData(on: board) : nil
        let sources = AgentImages.sources(fileURLs: urls, imageData: data, text: board.string(forType: .string))
        if !sources.isEmpty { return .images(sources) }
        let pictureOnly = urls.isEmpty && data == nil && hasPicture(board) && AgentImages.isIncidental(board.string(forType: .string))
        return pictureOnly ? .unreadable : .text
    }

    static func hasPicture(_ board: NSPasteboard) -> Bool { board.availableType(from: imageTypes) != nil }

    /// The picture's bytes in a form the encoder reads: PNG, TIFF, JPEG and the like as they are, PDF and old formats through NSImage.
    private static func imageData(on board: NSPasteboard) -> Data? {
        for type in imageTypes.filter({ ![.pdf, NSPasteboard.PasteboardType("com.apple.pict")].contains($0) }) {
            if let data = board.data(forType: type), !data.isEmpty { return data }
        }
        guard hasPicture(board) else { return nil }
        return NSImage(pasteboard: board)?.tiffRepresentation
    }
}
