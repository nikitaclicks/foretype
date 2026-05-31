import Foundation

/// What makes a focused field "the same field" across polls. Because
/// `elementHash` (a `CFHash`) can recycle across different elements, the
/// monotonic `changeSequence` is what guarantees identity does not collide.
/// See doc 03.
struct FocusIdentity: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let elementHash: Int
    let changeSequence: UInt64
}

/// How much to trust a resolved caret rectangle. Downstream code degrades
/// (clamps font, or hides ghost text) rather than mis-place text. See doc 03.
enum CaretQuality: Equatable, Sendable {
    case exact
    case derived
    case estimated
}

/// The caret's on-screen rectangle (Cocoa screen coordinates) plus a quality
/// rating and an optional observed character width (used for caret prediction
/// during insertion, doc 08).
struct CaretGeometry: Equatable, Sendable {
    let rect: CGRect
    let quality: CaretQuality
    let observedCharWidth: CGFloat?
}

/// Whether a focused field can be completed against.
enum FocusCapability: Equatable, Sendable {
    case supported
    /// e.g. secure field, or an app disabled by rule. No work begins.
    case blocked(reason: String)
    /// e.g. no usable text / selection / geometry available.
    case unsupported(reason: String)
}

/// An immutable read of the currently focused editable field. A snapshot with
/// `capability != .supported` must prevent any generation (doc 03/05).
struct FocusSnapshot: Equatable, Sendable {
    let identity: FocusIdentity
    let appName: String
    let role: String
    let subrole: String?
    /// Bounded window of text before the caret (the model context).
    let precedingText: String
    /// Bounded window of text after the caret (optional; may be empty).
    let trailingText: String
    let selection: NSRange
    let caret: CaretGeometry?
    /// The focused field's on-screen frame (Cocoa coords), used to anchor the
    /// ghost-text overlay. AX reports this far more reliably than the caret rect,
    /// so it is the primary positioning source (doc 03 / 08).
    let fieldRect: CGRect?
    let isSecure: Bool
    let capability: FocusCapability

    init(
        identity: FocusIdentity,
        appName: String,
        role: String,
        subrole: String?,
        precedingText: String,
        trailingText: String,
        selection: NSRange,
        caret: CaretGeometry?,
        fieldRect: CGRect? = nil,
        isSecure: Bool,
        capability: FocusCapability
    ) {
        self.identity = identity
        self.appName = appName
        self.role = role
        self.subrole = subrole
        self.precedingText = precedingText
        self.trailingText = trailingText
        self.selection = selection
        self.caret = caret
        self.fieldRect = fieldRect
        self.isSecure = isSecure
        self.capability = capability
    }
}
