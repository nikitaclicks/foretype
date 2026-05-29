import Foundation

/// Geometry driving the ghost-text overlay's position and sizing (doc 08).
struct OverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect      // Cocoa screen coords
    let fieldRect: CGRect?     // editable field bounds, for wrapping
    let quality: CaretQuality
}

/// What the overlay is currently showing. The overlay is a dumb renderer; the
/// coordinator decides whether to show (doc 08).
enum OverlayState: Equatable, Sendable {
    case hidden(reason: String)
    case visible(text: String, geometry: OverlayGeometry)
}
