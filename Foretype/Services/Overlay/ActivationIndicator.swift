import SwiftUI

/// A small, low-key marker rendered near the caret to signal "Foretype is active
/// in this field" even before a completion exists (doc 08). It follows the same
/// non-activating, click-through, geometry-driven rules as the ghost text and is
/// gated by `Settings.showActivationIndicator`. Strictly cosmetic — it must never
/// affect the completion pipeline.
@MainActor
struct ActivationIndicator: View {
    /// Resolved tint (shares the ghost-text color, or a secondary-label default).
    let color: Color
    /// Caret height, used to scale the marker so it sits naturally on the line.
    let caretHeight: CGFloat

    /// Diameter of the dot, scaled to the caret line and clamped to a subtle size.
    private var diameter: CGFloat {
        min(8, max(4, caretHeight * 0.22))
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .opacity(0.55)
            .allowsHitTesting(false)
    }
}
