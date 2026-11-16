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
    ("agent images: a paste or drop attaches image files, or image bytes when no text came with them", {
        let png = URL(fileURLWithPath: "/a/Shot.PNG"), pdf = URL(fileURLWithPath: "/a/doc.pdf")
        let bytes = Data([9])
        check(AgentImages.sources(fileURLs: [png, pdf], imageData: bytes, hasText: false) == [.file(png)], "only the image files")
        check(AgentImages.sources(fileURLs: [pdf], imageData: bytes, hasText: false).isEmpty, "other files paste as text")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, hasText: false) == [.data(bytes)], "a screenshot")
        check(AgentImages.sources(fileURLs: [], imageData: bytes, hasText: true).isEmpty, "copied text with a picture of itself stays text")
        check(AgentImages.sources(fileURLs: [], imageData: nil, hasText: true).isEmpty, "plain text")
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
