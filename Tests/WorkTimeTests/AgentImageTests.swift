import AppKit
import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

private func image(_ name: String) -> AgentImage {
    AgentImage(id: name, path: "/a/\(name).png", mediaType: "image/png", data: Data([1, 2, 3]), width: 10, height: 10)
}

let agentImageTests: [(name: String, run: () throws -> Void)] = [
    ("agent images: the long side is capped and smaller images keep their size", {
        check(AgentImages.fitSize(width: 3136, height: 1568) == (1568, 784), "wide")
        check(AgentImages.fitSize(width: 1000, height: 4704) == (333, 1568), "tall")
        check(AgentImages.fitSize(width: 800, height: 600) == (800, 600), "small")
        check(AgentImages.fitSize(width: 1568, height: 1568) == (1568, 1568), "at the limit")
    }),
    ("agent images: a paste or drop attaches image files, or image bytes when the text beside them is only a link or file name", {
        let png = URL(fileURLWithPath: "/a/Shot.PNG"), pdf = URL(fileURLWithPath: "/a/doc.pdf")
        let bytes = Data([9])
        check(AgentImages.sources(fileURLs: [png, pdf], imageData: bytes, text: nil) == [.file(png)], "only the image files")
        check(AgentImages.sources(fileURLs: [pdf], imageData: bytes, text: nil).isEmpty, "other files paste as text")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, text: nil) == [.data(bytes)], "a screenshot")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, text: "https://a.com/x.png") == [.data(bytes)], "copy image in a browser")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, text: "image.png\n") == [.data(bytes)], "a file name")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, text: "Total\t42").isEmpty, "copied cells stay text")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, text: "two\nlines").isEmpty, "copied text stays text")
        check(AgentImages.sources(fileURLs: [], imageData: nil, text: "hello").isEmpty, "plain text")
    }),
    ("agent images: what the composer reads from each kind of pasteboard", {
        let board = NSPasteboard(name: NSPasteboard.Name("worktime-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        func attached(_ fill: (NSPasteboard) -> Void) -> String {
            board.clearContents()
            fill(board)
            switch AgentPasteboard.read(board) {
            case .text: return "text"
            case .unreadable: return "unreadable"
            case .promised: return "promised"
            case .images(let sources): return "images \(sources.count)"
            }
        }
        let picture = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let tiff = picture.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        let jpeg = NSBitmapImageRep(data: tiff)!.representation(using: .jpeg, properties: [:])!
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 8, height: 8)
        if let consumer = CGDataConsumer(data: pdf), let context = CGContext(consumer: consumer, mediaBox: &box, nil) {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.red.cgColor)
            context.fill(box)
            context.endPDFPage()
            context.closePDF()
        }
        check(attached { $0.setData(png, forType: .png) } == "images 1", "png")
        check(attached { $0.setData(tiff, forType: .tiff) } == "images 1", "tiff")
        check(attached { $0.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")) } == "images 1", "jpeg")
        check(attached { $0.setData(pdf as Data, forType: .pdf) } == "images 1", "pdf")
        check(attached { $0.setData(png, forType: .png); $0.setString("https://a.com/x.png", forType: .string) } == "images 1", "image with its link")
        check(attached { $0.setData(tiff, forType: .tiff); $0.setString("12 | 34", forType: .string) } == "text", "cells with a picture of themselves")
        check(attached { $0.setString("hello", forType: .string) } == "text", "text")
        check(attached { $0.setData(Data([1, 2, 3]), forType: .pdf) } == "unreadable", "a picture nobody can read")
        check(attached { $0.setData(Data([1, 2, 3]), forType: .png) } == "images 1", "unreadable bytes go on to the encoder, which refuses them with a message")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).png")
        try png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        check(attached { $0.writeObjects([file as NSURL]) } == "images 1", "an image file")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).txt")
        check(attached { $0.writeObjects([other as NSURL]) } == "text", "another file")
        check(AgentPasteboard.hasPicture({ board.clearContents(); board.setData(png, forType: .png); return board }()), "paste is enabled for a picture")
    }),
    ("agent images: at most five fit, and big files are refused", {
        check(AgentImages.refusal(adding: 2, to: 3) == nil, "fits")
        check(AgentImages.refusal(adding: 1, to: 5) != nil, "full")
        check(AgentImages.tooLarge(AgentImages.maxSourceBytes) == nil, "at the limit")
        check(AgentImages.tooLarge(AgentImages.maxSourceBytes + 1) != nil, "over")
    }),
    ("agent images: the prompt names where the pictures are saved", {
        check(AgentImages.promptText("hi", images: []) == "hi", "no images")
        let one = AgentImages.promptText("what is this?", images: [image("a")])
        check(one == "what is this?\n\nAttached image, also saved at:\n- /a/a.png", "one")
        let two = AgentImages.promptText("", images: [image("a"), image("b")])
        check(two.hasPrefix("Look at the attached images.") && two.hasSuffix("- /a/a.png\n- /a/b.png"), "two, no text")
    }),
    ("agent images: the sidecar request carries them as base64 with their type", {
        let line = AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil, images: [image("a")]).line
        check(line.contains(#""mediaType":"image/png""#) && line.contains(#""data":"AQID""#), "images")
        check(!AgentRequest.prompt(text: "x", cwd: "/", sessionID: nil).line.contains("images"), "none by default")
    }),
    ("agent images: a sent message keeps the paths for its thumbnails", {
        let item = AgentItem(id: "user-0", kind: .user("hi"), images: ["/a/a.png"])
        check(item.images == ["/a/a.png"] && AgentItem(id: "t", kind: .text("x")).images.isEmpty, "paths")
    }),
]
