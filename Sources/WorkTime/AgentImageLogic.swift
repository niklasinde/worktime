import Foundation

/// An image attached to a prompt, already downscaled and encoded, with the copy kept on disk so tools can read it.
struct AgentImage: Identifiable, Equatable {
    let id: String
    let path: String
    let mediaType: String
    let data: Data
    let width: Int
    let height: Int

    var json: [String: String] { ["mediaType": mediaType, "data": data.base64EncodedString()] }
}

/// Where an image to attach comes from: a file on disk or the bytes themselves, like a screenshot on the pasteboard.
enum AgentImageSource: Equatable {
    case file(URL)
    case data(Data)
}

enum AgentImages {
    static let maxSide = 1568
    static let maxCount = 5
    static let maxSourceBytes = 25 * 1024 * 1024
    static let maxEncodedBytes = 4 * 1024 * 1024
    static let fileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    static func isImageFile(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    /// The size an image is scaled to so its long side is at most `maxSide`; smaller ones keep their size.
    static func fitSize(width: Int, height: Int, maxSide: Int = maxSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxSide, width > 0, height > 0 else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// What a paste or drop brings: image files first, else image bytes when the text beside them is only a link or a file name
    /// ("Copy image" in a browser or Slack), not the text itself (copied cells and rich text carry a picture of themselves).
    /// Nothing means paste the text as usual.
    static func sources(fileURLs: [URL], imageData: Data?, text: String?) -> [AgentImageSource] {
        if !fileURLs.isEmpty { return fileURLs.filter(isImageFile).map(AgentImageSource.file) }
        guard let imageData, isIncidental(text) else { return [] }
        return [.data(imageData)]
    }

    /// Text that only names the picture it came with: nothing, a link, or the name of an image file.
    static func isIncidental(_ text: String?) -> Bool {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: \.isNewline) else { return false }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), ["http", "https", "file", "data"].contains(scheme) { return true }
        return isImageFile(URL(fileURLWithPath: trimmed))
    }

    /// Why more images cannot be attached, nil when there is room.
    static func refusal(adding count: Int, to existing: Int) -> String? {
        existing + count > maxCount ? "At most \(maxCount) images fit in one message." : nil
    }

    static func tooLarge(_ bytes: Int) -> String? {
        bytes > maxSourceBytes ? "That image is over \(maxSourceBytes / 1024 / 1024) MB." : nil
    }

    static let unreadable = "That file could not be read as an image."

    /// The prompt the agent gets: what was typed, then where the pictures are saved so its tools can open them.
    static func promptText(_ text: String, images: [AgentImage]) -> String {
        guard !images.isEmpty else { return text }
        let body = text.isEmpty ? "Look at the attached \(images.count == 1 ? "image" : "images")." : text
        let paths = images.map { "- \($0.path)" }.joined(separator: "\n")
        return "\(body)\n\nAttached \(images.count == 1 ? "image, also" : "images, also") saved at:\n\(paths)"
    }
}
