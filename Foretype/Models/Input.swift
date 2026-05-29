import Foundation

/// The small semantic vocabulary raw key events are mapped to by the pure
/// `InputClassifier` (doc 04). The coordinator reacts to the classified kind,
/// never to raw keycodes.
enum InputEvent: Equatable, Sendable {
    case accept              // Tab — accept next word/chunk of the completion
    case textMutation        // a character that changes text → (re)request
    case shortcutMutation    // Cmd/Ctrl combos that likely change text → re-request
    case navigation          // arrows, home/end, page up/down → dismiss, no re-request
    case dismiss             // Esc, copy, and other "stop" gestures → dismiss
    case ignored             // everything else
}
