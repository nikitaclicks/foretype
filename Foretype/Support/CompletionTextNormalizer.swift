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
    /// 3. Strip an echoed prefix of `request.precedingText` the model parroted back.
    /// 4. If `request.precedingText` ends in a space, drop a single leading space.
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

        // 3. Strip an echoed prefix of the preceding text.
        text = stripEchoedPrefix(text, preceding: request.precedingText)

        // 4. If the caret already sits after a space, don't double it.
        if request.precedingText.hasSuffix(" "), text.hasPrefix(" ") {
            text.removeFirst()
        }

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

    // MARK: - Echo stripping

    /// If the model echoed a tail of the preceding text, drop it. We look for the
    /// longest suffix of `preceding` that the output starts with.
    private static func stripEchoedPrefix(_ text: String, preceding: String) -> String {
        guard !preceding.isEmpty, !text.isEmpty else { return text }

        // If the output begins with the full preceding text, strip it outright.
        if text.hasPrefix(preceding) {
            return String(text.dropFirst(preceding.count))
        }

        // Find the longest suffix of `preceding` (broken on whitespace boundaries)
        // that the text starts with.
        let chars = Array(preceding)
        // Candidate boundaries: start of each "word" run inside preceding, plus 0.
        var boundaries: [Int] = [0]
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count { boundaries.append(j) }
                i = j
            } else {
                i += 1
            }
        }
        // Longest (earliest boundary) wins.
        for b in boundaries {
            let suffix = String(chars[b...])
            if !suffix.isEmpty, text.hasPrefix(suffix) {
                return String(text.dropFirst(suffix.count))
            }
        }
        return text
    }
}
