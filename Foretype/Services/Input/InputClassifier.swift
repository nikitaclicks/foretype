import CoreGraphics
import Foundation

/// Pure mapping from a raw keyboard event (virtual keycode + modifier flags) to
/// the small semantic `InputEvent` vocabulary (doc 04). No side effects, no
/// state — fully testable. The coordinator reacts to the classified kind, never
/// to raw keycodes.
enum InputClassifier {
    // Virtual keycodes (US ANSI layout) relevant to classification.
    private enum Key {
        static let tab: Int64 = 48
        static let `return`: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let delete: Int64 = 51       // backspace
        static let forwardDelete: Int64 = 117
        static let escape: Int64 = 53
        static let space: Int64 = 49

        static let leftArrow: Int64 = 123
        static let rightArrow: Int64 = 124
        static let downArrow: Int64 = 125
        static let upArrow: Int64 = 126
        static let home: Int64 = 115
        static let end: Int64 = 119
        static let pageUp: Int64 = 116
        static let pageDown: Int64 = 121

        // Shortcut-relevant letter keys.
        static let c: Int64 = 8
        static let v: Int64 = 9
        static let x: Int64 = 7
        static let z: Int64 = 6
        static let a: Int64 = 0
    }

    /// Returns true if the keycode produces literal text (letters, digits,
    /// punctuation) absent command-class modifiers.
    private static func isCharacterProducing(_ keyCode: Int64) -> Bool {
        // Function keys (F1..F20) live in 122/120/99/118/96..101/109/103/111/
        // 105/107/113 and the media/keypad region; rather than enumerate every
        // character key, we treat anything not explicitly a known
        // navigation/control/function key as character-producing only when it
        // falls inside the main typing block. The simplest robust heuristic:
        // explicitly reject the known non-character keys (handled by the caller)
        // and the function-key range, accept the rest of the low keycodes.
        if isFunctionKey(keyCode) { return false }
        // Main typing area + keypad digits all sit below 0x5F (95). Pure
        // modifiers are handled before this is reached.
        return keyCode >= 0 && keyCode < 95
    }

    private static func isFunctionKey(_ keyCode: Int64) -> Bool {
        switch keyCode {
        // F1..F20 virtual keycodes.
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
             105, 107, 113, 106, 64, 79, 80, 90:
            return true
        default:
            return false
        }
    }

    static func classify(keyCode: Int64, flags: CGEventFlags) -> InputEvent {
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let commandClass = command || control

        switch keyCode {
        case Key.tab:
            // Bare Tab is the accept gesture; Cmd/Ctrl/Opt+Tab is app/space
            // switching → ignore.
            return (command || control || option) ? .ignored : .accept

        case Key.escape:
            return .dismiss

        case Key.leftArrow, Key.rightArrow, Key.downArrow, Key.upArrow,
             Key.home, Key.end, Key.pageUp, Key.pageDown:
            return .navigation

        case Key.return, Key.keypadEnter, Key.delete, Key.forwardDelete:
            // Editing keys: with command-class modifiers they are unusual; treat
            // a plain press as a text mutation.
            return commandClass ? .ignored : .textMutation

        default:
            break
        }

        // Command/Control combinations that change or copy text.
        if commandClass {
            switch keyCode {
            case Key.c:
                return .dismiss            // copy
            case Key.v, Key.x, Key.a, Key.z:
                return .shortcutMutation   // paste / cut / select-all / undo+redo
            default:
                // Other command-class chords (navigation shortcuts, app
                // commands) do not edit the field → ignore.
                return .ignored
            }
        }

        // No command-class modifiers: literal characters mutate the text.
        // Option may compose accented characters, which is still a mutation.
        if isCharacterProducing(keyCode) {
            return .textMutation
        }

        // Function keys, media keys, pure-modifier presses, and anything else.
        return .ignored
    }
}
