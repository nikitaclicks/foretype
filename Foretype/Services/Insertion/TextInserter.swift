import CoreGraphics
import Foundation

/// Inserts accepted completion text by synthesizing keyboard events (doc 09),
/// not by writing the field's Accessibility value — synthetic input is what the
/// field already expects and works across nearly every standard text control.
///
/// Before posting, it registers the synthetic key-down count with the
/// `SyntheticInputGuard` so `KeyboardTap` does not treat the inserted characters
/// as user typing and trigger a new prediction.
@MainActor
final class TextInserter: TextInserting {
    private let guardian: SyntheticInputGuard

    init(guard: SyntheticInputGuard) {
        self.guardian = `guard`
    }

    func insert(_ text: String) -> Bool {
        // Strip carriage returns; never inject newlines from a model guess.
        let cleaned = text.replacingOccurrences(of: "\r", with: "")
        guard !cleaned.isEmpty else { return true }

        // We post one key-down/up pair per character, carrying the character as
        // a Unicode payload. Each character is one synthetic key-down event.
        let characters = Array(cleaned)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        // Bracket the whole burst with the guard before posting anything.
        guardian.expect(count: characters.count)

        for character in characters {
            let utf16 = Array(String(character).utf16)

            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: true
                ),
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                )
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        return true
    }
}
