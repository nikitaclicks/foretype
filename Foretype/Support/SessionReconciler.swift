import Foundation

/// The result of advancing an `ActiveSession` (doc 05). `advance(n)` skips `n`
/// characters of the remainder; `diverged` means the user typed something other
/// than the next predicted character (session invalid); `exhausted` means there
/// is nothing left to consume.
enum ReconcileOutcome: Equatable {
    case advance(Int)
    case diverged
    case exhausted
}

/// Pure chunking + typed-through logic for word-by-word acceptance (docs 05, 09).
///
/// A "chunk" is the next word plus its trailing boundary run (spaces and/or
/// punctuation), so each `Tab` commits a natural unit and the remaining ghost
/// text starts cleanly at the next word. No I/O, no UI, no AX — fully unit
/// testable.
enum SessionReconciler {
    /// The next chunk to insert on `Tab`: the next word PLUS its trailing
    /// boundary run (spaces / punctuation). If the remainder is a single word
    /// with no trailing boundary, the whole remainder is the chunk. Returns ""
    /// when the remainder is empty.
    static func nextChunk(_ session: ActiveSession) -> String {
        let chars = Array(session.remainder)
        guard !chars.isEmpty else { return "" }

        var index = 0

        // Leading boundary run (e.g. the remainder begins with spaces /
        // punctuation): consume it as its own chunk so the next word starts clean.
        if isBoundary(chars[0]) {
            while index < chars.count, isBoundary(chars[index]) {
                index += 1
            }
            return String(chars[0..<index])
        }

        // Word run: consume word characters first.
        while index < chars.count, !isBoundary(chars[index]) {
            index += 1
        }

        // Trailing boundary run following the word.
        while index < chars.count, isBoundary(chars[index]) {
            index += 1
        }

        return String(chars[0..<index])
    }

    /// Reconcile a single typed character against the session's remainder.
    /// Empty remainder → `.exhausted`. Typed char matches the first remaining
    /// char → `.advance(1)` (the user typed what we were about to suggest).
    /// Otherwise → `.diverged` (session is invalidated).
    static func reconcileTyped(_ session: ActiveSession, typed: Character) -> ReconcileOutcome {
        guard let first = session.remainder.first else { return .exhausted }
        return typed == first ? .advance(1) : .diverged
    }

    // MARK: - Boundary classification

    /// A boundary character is anything that is not part of a "word": whitespace
    /// and punctuation both terminate a word and are swept up as the trailing run.
    private static func isBoundary(_ character: Character) -> Bool {
        for scalar in character.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            return false
        }
        return true
    }
}
