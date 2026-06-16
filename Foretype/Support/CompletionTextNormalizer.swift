import Foundation

/// Pure, coordinator-side cleanup applied uniformly to *all* engine output before
/// it becomes an `ActiveSession` (doc 07, "Shared text normalization"). Both
/// engines return raw model text; this enum makes display behavior consistent and
/// testable. No I/O, no actor isolation — identical inputs yield identical output.
enum CompletionTextNormalizer {

    /// Clean raw model output into short inline continuation text.
    ///
    /// Steps, in order:
    /// 1. Remove carriage returns.
    /// 2. Strip wrapping code fences, then leading labels ("Continuation:"), then
    ///    wrapping quotes.
    /// 3. Reconcile against `request.precedingText`: strip an echoed in-progress
    ///    word and normalize the separator space (see `reconcile`).
    /// 5. Cap to the word ceiling implied by `request.lengthHint`.
    /// 6. Return "" if nothing meaningful remains.
    static func normalize(_ raw: String, request: CompletionRequest) -> String {
        // 1. Remove carriage returns (keep newlines for now; collapsed later).
        var text = raw.replacingOccurrences(of: "\r", with: "")

        // 2a. Strip wrapping code fences (```lang ... ```).
        text = stripCodeFences(text)

        // 2b. Strip a leading label like "Continuation:" / "Completion -".
        text = stripLeadingLabel(text)

        // 2c. Strip wrapping quotes.
        text = stripWrappingQuotes(text)

        // 3. Reconcile the model output against the text before the caret:
        //    strip an echoed in-progress word and own the separator space, so the
        //    result inserts cleanly at the caret with no duplication or fused words.
        text = reconcile(text, preceding: request.precedingText)

        // 5. Cap to the word ceiling for the requested length.
        text = capToWordCeiling(text, hint: request.lengthHint)

        // 6. Empty if nothing meaningful remains.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        return text
    }

    // MARK: - Word ceilings

    /// Maximum words kept for each length hint. A final safety guard — the model
    /// is also instructed to respect length, but it cannot be trusted to.
    private static func wordCeiling(for hint: LengthHint) -> Int {
        switch hint {
        case .short:  return 7    // ~3–7 words
        case .medium: return 12   // ~7–12 words
        case .long:   return 20   // ~12–20 words
        }
    }

    private static func capToWordCeiling(_ text: String, hint: LengthHint) -> String {
        let ceiling = wordCeiling(for: hint)
        guard ceiling > 0 else { return "" }

        // Find the end index of the ceiling-th word; truncate there. We walk the
        // string counting whitespace→non-whitespace transitions as word starts, and
        // cut at the start of the (ceiling+1)-th word so interior spacing within the
        // kept portion is preserved. A leading space is preserved as part of the cut.
        var wordCount = 0
        var inWord = false
        var cutIndex = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            if !isSpace, !inWord {
                inWord = true
                wordCount += 1
                if wordCount > ceiling {
                    cutIndex = index
                    break
                }
            } else if isSpace {
                inWord = false
            }
            index = text.index(after: index)
        }
        // Drop trailing whitespace from the kept portion (it'd be a dangling gap).
        let kept = text[text.startIndex..<cutIndex]
        let trimmedTail = kept.reversed().prefix { $0.isWhitespace }.count
        return String(kept.dropLast(trimmedTail))
    }

    // MARK: - Code fences

    private static func stripCodeFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return text }
        // Drop the opening fence line (``` optionally followed by a language tag).
        var lines = trimmed.components(separatedBy: "\n")
        guard !lines.isEmpty else { return text }
        lines.removeFirst()
        // Drop a trailing closing fence line if present.
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Leading labels

    /// Strip a leading "Label:" or "Label -" prefix (e.g. "Continuation:").
    private static func stripLeadingLabel(_ text: String) -> String {
        let leading = text.prefix { $0 == " " || $0 == "\t" || $0 == "\n" }
        let body = text[text.index(text.startIndex, offsetBy: leading.count)...]
        // A label is a short run of letters/spaces up to a ':' or ' - ' separator,
        // appearing before any newline.
        guard let lineEnd = body.firstIndex(of: "\n") else {
            return stripLabelFromLine(String(text))
        }
        let firstLine = String(body[..<lineEnd])
        let rest = String(body[lineEnd...])
        let stripped = stripLabelFromLine(firstLine)
        if stripped != firstLine {
            return String(leading) + stripped + rest
        }
        return text
    }

    private static func stripLabelFromLine(_ line: String) -> String {
        for separator in [":", " - ", " — "] {
            if let range = line.range(of: separator) {
                let label = line[line.startIndex..<range.lowerBound]
                // Only treat as a label if it's a short alpha phrase (<= 3 words,
                // letters/spaces only) — avoids eating real text containing a colon.
                let words = label.split(separator: " ")
                let isLabel = !label.isEmpty
                    && words.count <= 3
                    && label.allSatisfy { $0.isLetter || $0 == " " }
                if isLabel {
                    let after = line[range.upperBound...]
                        .drop(while: { $0 == " " || $0 == "\t" })
                    return String(after)
                }
            }
        }
        return line
    }

    // MARK: - Wrapping quotes

    private static func stripWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"),
            ("\u{201C}", "\u{201D}"), // “ ”
            ("\u{2018}", "\u{2019}"), // ‘ ’
            ("`", "`")
        ]
        for (open, close) in pairs where trimmed.count >= 2
            && trimmed.first == open && trimmed.last == close {
            // Only treat as wrapping quotes when the same mark opens and closes the
            // whole string; an interior quote (e.g. said "yes") is left intact.
            return String(trimmed.dropFirst().dropLast())
        }
        return text
    }

    // MARK: - Caret reconciliation

    /// Reconcile raw model output with the text before the caret so it inserts
    /// cleanly: strip any echoed in-progress word, and own the separator space.
    ///
    /// The model owns the separator (see `PromptBuilder`): it continues the
    /// in-progress word with NO leading space, and begins a new word WITH a single
    /// leading space. The normalizer therefore never fabricates a separator — it
    /// only strips echoes and normalizes the model-supplied leading space. Steps:
    /// 1. Echoed suffix: drop the longest suffix of the preceding text that the
    ///    output begins with, where that suffix starts at a word boundary. This
    ///    covers a full echo (suffix from the start), a repeated in-progress word
    ///    (the trailing word run), and the model echoing one or more whole trailing
    ///    words of the context. No separator is invented here.
    /// 2. Leading whitespace: drop it entirely when the caret already follows
    ///    whitespace, else collapse a leading run to a single space.
    private static func reconcile(_ text: String, preceding: String) -> String {
        guard !text.isEmpty else { return text }
        var text = text

        // 1. Strip the longest boundary-anchored suffix of the preceding context
        //    that the model echoed back. Candidate suffixes start at index 0 or
        //    immediately after a word boundary (so they begin with a word character,
        //    never whitespace); the first match walking longest→shortest is the
        //    longest echo. We never fabricate a separator — only strip the echo.
        for start in wordStartIndices(preceding) {
            let suffix = String(preceding[start...])
            if !suffix.isEmpty, let remainder = dropMatchingPrefix(text, partial: suffix) {
                text = remainder
                break
            }
        }

        // 2. Leading-whitespace normalization.
        if let last = preceding.last, last.isWhitespace {
            // The caret already follows whitespace — the separator is in place.
            text = String(text.drop(while: { $0.isWhitespace }))
        } else if let first = text.first, first.isWhitespace {
            // Collapse a leading whitespace run to a single space separator.
            text = " " + text.drop(while: { $0.isWhitespace })
        }

        return text
    }

    /// Word-start indices of `text`, ordered so the suffix `text[index...]` runs
    /// from longest to shortest. A word start is index 0 (the whole string) or any
    /// index whose previous character is a boundary and whose own character is not
    /// — so each suffix begins with a word character, never whitespace.
    private static func wordStartIndices(_ text: String) -> [String.Index] {
        guard !text.isEmpty else { return [] }
        var indices: [String.Index] = []
        var index = text.startIndex
        var previousWasBoundary = true
        while index < text.endIndex {
            let isBound = isBoundary(text[index])
            if previousWasBoundary, !isBound {
                indices.append(index)
            }
            previousWasBoundary = isBound
            index = text.index(after: index)
        }
        return indices
    }

    /// If `text` begins with `partial` (compared case-insensitively), drop that
    /// many characters and return the remainder (original case preserved);
    /// otherwise `nil`.
    private static func dropMatchingPrefix(_ text: String, partial: String) -> String? {
        guard text.count >= partial.count else { return nil }
        let head = text.prefix(partial.count)
        guard head.lowercased() == partial.lowercased() else { return nil }
        return String(text.dropFirst(partial.count))
    }

    /// A boundary character terminates a word: whitespace, punctuation, or
    /// symbols. Mirrors `SessionReconciler.isBoundary` so chunking and
    /// normalization agree on where words begin and end.
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
