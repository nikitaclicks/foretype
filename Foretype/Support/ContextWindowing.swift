import Foundation

/// ContextWindowing (doc 06) — pure helpers that bound the text pulled from a
/// focus snapshot before it enters a `CompletionRequest`. Keeping context to a
/// small tail window prevents far-away stale text from steering the completion
/// and keeps token cost predictable. No I/O, no actor isolation: identical
/// input always yields identical output.
enum ContextWindowing {

    /// Maximum number of characters retained from the preceding text.
    private static let precedingCharLimit = 1000
    /// Maximum number of words retained from the preceding text.
    private static let precedingWordLimit = 50
    /// Maximum number of characters retained from the trailing text.
    private static let trailingCharLimit = 200

    /// Window the text *before* the caret, retaining the TAIL (the part closest
    /// to the caret). Applies both a character cap (~1000) and a word cap (~50);
    /// whichever cap removes more from the head wins. Short text passes through
    /// untouched.
    static func windowedPreceding(_ text: String) -> String {
        if text.isEmpty { return text }

        // First apply the word cap on the tail. Splitting on whitespace and
        // rejoining would lose the original spacing, so instead we locate the
        // start index of the last `precedingWordLimit` words and slice there.
        var result = Substring(text)

        let words = result.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.isWhitespace }
        )
        if words.count > precedingWordLimit {
            // Keep the last `precedingWordLimit` words. Find the start index of
            // the first word we want to retain, and slice from there.
            let firstKeptWord = words[words.count - precedingWordLimit]
            if let startIndex = firstKeptWord.indices.first {
                result = result[startIndex...]
            }
        }

        // Then apply the character cap, again retaining the tail.
        if result.count > precedingCharLimit {
            let startIndex = result.index(result.endIndex, offsetBy: -precedingCharLimit)
            result = result[startIndex...]
        }

        return String(result)
    }

    /// Window the text *after* the caret, retaining a short HEAD (~200 chars).
    /// The trailing text only helps the model avoid duplicating what already
    /// follows the caret, so a small head window is enough. Short text passes
    /// through untouched; empty stays empty.
    static func windowedTrailing(_ text: String) -> String {
        if text.isEmpty { return text }
        if text.count <= trailingCharLimit { return text }
        let endIndex = text.index(text.startIndex, offsetBy: trailingCharLimit)
        return String(text[..<endIndex])
    }
}
