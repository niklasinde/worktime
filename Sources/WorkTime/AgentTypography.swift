import AppKit
import SwiftUI

extension TranscriptFace {
    /// Whether this Mac has the face; the system designs always are.
    var isAvailable: Bool {
        guard let family else { return true }
        return NSFontManager.shared.availableFontFamilies.contains(family)
    }

    static var available: [TranscriptFace] { allCases.filter(\.isAvailable) }
}

extension TranscriptTypography {
    func font(size: Double? = nil, weight: Font.Weight = .regular) -> Font {
        let size = size ?? self.size
        switch face {
        case .system: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .newYork: return .system(size: size, weight: weight, design: .serif)
        case .avenirNext, .seravek, .charter, .helveticaNeue:
            guard let family = face.family, face.isAvailable else { return .system(size: size, weight: weight) }
            return .custom(family, size: size).weight(weight)
        }
    }

    var body: Font { font() }
    var heading: Font { font(size: headingSize, weight: .semibold) }
    var small: Font { font(size: smallSize) }
    var code: Font { .system(size: codeSize, design: .monospaced) }

    /// The composer's font, so what is typed reads like what is answered.
    var nsFont: NSFont {
        let base = NSFont.systemFont(ofSize: size)
        switch face {
        case .system: return base
        case .rounded: return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .newYork: return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .avenirNext, .seravek, .charter, .helveticaNeue:
            guard let family = face.family else { return base }
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? base
        }
    }
}

private struct TranscriptTypographyKey: EnvironmentKey {
    static let defaultValue: TranscriptTypography? = nil
}

extension EnvironmentValues {
    /// Nil where the text keeps the system's look, which is everywhere outside the agent transcript and the chats.
    var transcriptTypography: TranscriptTypography? {
        get { self[TranscriptTypographyKey.self] }
        set { self[TranscriptTypographyKey.self] = newValue }
    }
}

/// Gives the content inside it the transcript typography the user chose in Settings → Agent.
private struct TranscriptTypographyScope: ViewModifier {
    @AppStorage(TranscriptTypography.faceKey) private var face = TranscriptTypography.standard.face.rawValue
    @AppStorage(TranscriptTypography.sizeKey) private var size = TranscriptTypography.standard.size
    @AppStorage(TranscriptTypography.lineSpacingKey) private var lineSpacing = TranscriptTypography.standard.lineSpacing
    @AppStorage(TranscriptTypography.paragraphSpacingKey) private var paragraphSpacing = TranscriptTypography.standard.paragraphSpacing

    func body(content: Content) -> some View {
        let typography = TranscriptTypography.make(face: face, size: size, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing)
        content
            .environment(\.transcriptTypography, typography)
            .font(typography.body)
    }
}

extension View {
    func transcriptTypography() -> some View { modifier(TranscriptTypographyScope()) }
}
