import SwiftUI

/// The SwiftUI body of the ghost-text overlay (doc 08): a single faded run of
/// text that reads as the natural continuation of the user's line. It is a pure
/// renderer — text, font size, color, and wrapping width are pushed in by the
/// `GhostTextOverlay` controller. It never decides whether to show.
@MainActor
struct GhostTextView: View {
    /// The remainder of the active session to preview.
    let text: String
    /// The host field's font family, when AX exposed it; `nil` falls back to the
    /// system font. Matching the family makes the preview read as the same text.
    let fontName: String?
    /// Point size: the host field's real size when known, else a caret-height
    /// estimate (resolved by the controller).
    let fontSize: CGFloat
    /// Resolved ghost-text color (configured tone, or a secondary-label default).
    let color: Color
    /// Maximum width before wrapping back to the field's left edge. `nil` lets
    /// the text run as wide as it needs (single visual line).
    let wrapWidth: CGFloat?

    /// Match the host font family when known (fixed size — never scaled by Dynamic
    /// Type, since we mirror the field's literal point size), else the system font.
    private var resolvedFont: Font {
        if let fontName, !fontName.isEmpty {
            return .custom(fontName, fixedSize: fontSize)
        }
        return .system(size: fontSize)
    }

    var body: some View {
        Text(text)
            .font(resolvedFont)
            .foregroundColor(color)
            // Wrap onto subsequent lines when a width is supplied; otherwise the
            // run stays on one line and the panel sizes to fit it.
            .lineLimit(wrapWidth == nil ? 1 : nil)
            .fixedSize(horizontal: wrapWidth == nil, vertical: true)
            .frame(
                maxWidth: wrapWidth,
                alignment: .topLeading
            )
            // No background, no shadow — purely a text layer.
            .allowsHitTesting(false)
    }
}
