import Foundation

/// A typeface for the transcript's prose. All of them ship with macOS; code stays monospaced whatever is chosen.
enum TranscriptFace: String, CaseIterable, Identifiable, Sendable {
    case avenirNext, seravek, system, rounded, newYork, charter, helveticaNeue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avenirNext: "Avenir Next"
        case .seravek: "Seravek"
        case .system: "System"
        case .rounded: "System Rounded"
        case .newYork: "New York"
        case .charter: "Charter"
        case .helveticaNeue: "Helvetica Neue"
        }
    }

    /// The font family to look up, nil for the system designs.
    var family: String? {
        switch self {
        case .avenirNext: "Avenir Next"
        case .seravek: "Seravek"
        case .charter: "Charter"
        case .helveticaNeue: "Helvetica Neue"
        case .system, .rounded, .newYork: nil
        }
    }
}

/// How the transcript's prose looks: the face, its size and the room between lines and paragraphs.
struct TranscriptTypography: Equatable, Sendable {
    static let sizes = 12.0...20.0
    static let lineSpacings = 0.0...10.0
    static let paragraphSpacings = 4.0...20.0
    static let faceKey = "agentTranscriptFace"
    static let sizeKey = "agentTranscriptSize"
    static let lineSpacingKey = "agentTranscriptLineSpacing"
    static let paragraphSpacingKey = "agentTranscriptParagraphSpacing"

    var face: TranscriptFace
    var size: Double
    var lineSpacing: Double
    var paragraphSpacing: Double

    /// Avenir Next at 15 pt with about 1.5 line height: open and humanist, the closest of the built-in faces to Claude's own text.
    static let standard = TranscriptTypography(face: .avenirNext, size: 15, lineSpacing: 5, paragraphSpacing: 10)

    /// The setting as stored: an unknown face falls back to the standard one and every number is kept in its range.
    static func make(face: String, size: Double, lineSpacing: Double, paragraphSpacing: Double) -> TranscriptTypography {
        TranscriptTypography(face: TranscriptFace(rawValue: face) ?? standard.face,
                             size: size.clamped(to: sizes),
                             lineSpacing: lineSpacing.clamped(to: lineSpacings),
                             paragraphSpacing: paragraphSpacing.clamped(to: paragraphSpacings))
    }

    var headingSize: Double { size + 2 }
    var codeSize: Double { max(size - 2, 11) }
    var smallSize: Double { max(size - 2, 11) }

    /// The room above a block: a list item that follows another keeps close to it, anything else gets the paragraph gap.
    func gap(listItemAfterListItem: Bool) -> Double {
        listItemAfterListItem ? max(lineSpacing, 2) + 1 : paragraphSpacing
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
