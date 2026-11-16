import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns pasted or dropped pictures into `AgentImage`s: scaled down, encoded as PNG or JPEG and saved under Attachments.
enum AgentImageCodec {
    struct Rejected: Error { let message: String }

    static func load(_ source: AgentImageSource) throws -> AgentImage {
        switch source {
        case .file(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let message = AgentImages.tooLarge(size) { throw Rejected(message: message) }
            guard let data = try? Data(contentsOf: url) else { throw Rejected(message: AgentImages.unreadable) }
            return try encode(data)
        case .data(let data):
            if let message = AgentImages.tooLarge(data.count) { throw Rejected(message: message) }
            return try encode(data)
        }
    }

    static func encode(_ data: Data) throws -> AgentImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Rejected(message: AgentImages.unreadable) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: AgentImages.maxSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Rejected(message: AgentImages.unreadable) }
        var (bytes, type) = (try output(image, type: .png), UTType.png)
        if bytes.count > AgentImages.maxEncodedBytes { (bytes, type) = (try output(image, type: .jpeg, quality: 0.85), .jpeg) }
        guard bytes.count <= AgentImages.maxEncodedBytes else { throw Rejected(message: "That image is too large even after shrinking it.") }
        let id = UUID().uuidString
        let url = try save(bytes, id: id, fileExtension: type == .png ? "png" : "jpg")
        return AgentImage(id: id, path: url.path, mediaType: type == .png ? "image/png" : "image/jpeg", data: bytes,
                          width: image.width, height: image.height)
    }

    private static func output(_ image: CGImage, type: UTType, quality: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw Rejected(message: AgentImages.unreadable) }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw Rejected(message: AgentImages.unreadable) }
        return data as Data
    }

    private static func save(_ data: Data, id: String, fileExtension: String) throws -> URL {
        let folder = AppPaths.attachments
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
