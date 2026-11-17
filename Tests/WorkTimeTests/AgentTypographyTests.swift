import Foundation
#if canImport(WorkTime)
@testable import WorkTime
#endif

let agentTypographyTests: [(name: String, run: () throws -> Void)] = [
    ("the standard transcript text is Avenir Next at 15 points with open spacing", {
        let standard = TranscriptTypography.standard
        check(standard.face == .avenirNext && standard.size == 15, "face and size")
        check(standard.lineSpacing == 5 && standard.paragraphSpacing == 10, "spacing")
        check(standard.headingSize == 17 && standard.codeSize == 13, "heading and code sizes follow the size")
    }),

    ("the stored setting is kept in range and an unknown face falls back", {
        let made = TranscriptTypography.make(face: "comic", size: 99, lineSpacing: -3, paragraphSpacing: 1)
        check(made.face == .avenirNext, "unknown face: \(made.face)")
        check(made.size == 20 && made.lineSpacing == 0 && made.paragraphSpacing == 4, "clamped: \(made)")
        let small = TranscriptTypography.make(face: "newYork", size: 3, lineSpacing: 50, paragraphSpacing: 50)
        check(small.face == .newYork && small.size == 12 && small.lineSpacing == 10 && small.paragraphSpacing == 20, "other end: \(small)")
        check(TranscriptTypography.make(face: "system", size: 14, lineSpacing: 4, paragraphSpacing: 8).size == 14, "in range is kept")
    }),

    ("only the named faces need a font family and the system designs do not", {
        for face in TranscriptFace.allCases {
            let named: Set<TranscriptFace> = [.avenirNext, .seravek, .charter, .helveticaNeue]
            check((face.family != nil) == named.contains(face), "\(face)")
            check(!face.title.isEmpty, "\(face) has a title")
        }
        check(Set(TranscriptFace.allCases.map(\.title)).count == TranscriptFace.allCases.count, "titles are distinct")
    }),

    ("a list item after another list item sits close and anything else gets the paragraph gap", {
        let standard = TranscriptTypography.standard
        check(standard.gap(listItemAfterListItem: false) == 10, "paragraph gap")
        check(standard.gap(listItemAfterListItem: true) == 6, "list items: \(standard.gap(listItemAfterListItem: true))")
        let tight = TranscriptTypography.make(face: "system", size: 13, lineSpacing: 0, paragraphSpacing: 4)
        check(tight.gap(listItemAfterListItem: true) == 3, "never closer than lines of text")
    }),
]
