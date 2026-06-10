import Foundation
import CoreGraphics

/// SurroundingContextWindowing (doc 06) — pure helpers that bound and clean the
/// *surrounding* AX content gathered from around the focused field before it
/// enters a `CompletionRequest`. Like `ContextWindowing`, this is pure: no I/O,
/// no actor isolation, identical input always yields identical output. The raw
/// AX walk that produces the fragments lives in `SurroundingContextResolver`;
/// all the math (dedup, per-fragment cap, total budget, overlap removal) lives
/// here so it is unit-testable.
enum SurroundingContextWindowing {

    /// Maximum characters retained from the whole assembled surrounding context.
    /// Sits comfortably under the ~1000-char preceding window so a request stays
    /// modest; the head (earliest, highest-priority fragments: title →
    /// description → recent comments) is retained.
    static let totalCharBudget = 3000
    /// Maximum characters retained from any single fragment, so one huge node
    /// (e.g. a pasted wall of text) cannot eat the whole budget.
    static let perFragmentCharCap = 240
    /// Maximum number of distinct fragments retained.
    static let maxFragments = 200

    /// Assemble raw collected fragments into a single bounded, de-duplicated,
    /// newline-joined string. Trims each fragment, drops empties, caps each to
    /// `perFragmentCharCap`, de-duplicates by a normalized key (Chromium often
    /// exposes the same text on a wrapper title and its child static text), keeps
    /// at most `maxFragments`, then caps the joined result to `totalCharBudget`
    /// retaining the head. Fragment order is preserved (document order).
    static func assemble(fragments: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in fragments {
            if kept.count >= maxFragments { break }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let capped = cappedToHead(trimmed, limit: perFragmentCharCap)
            let key = normalizedKey(capped)
            if key.isEmpty { continue }
            if seen.contains(key) { continue }
            seen.insert(key)
            kept.append(capped)
        }
        return windowed(kept.joined(separator: "\n"))
    }

    /// Bound an already-assembled surrounding-context string: trim, then cap to
    /// `totalCharBudget` retaining the head. Idempotent — safe for `PromptBuilder`
    /// to apply again to whatever the coordinator passes in. Empty stays empty.
    static func windowed(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return cappedToHead(trimmed, limit: totalCharBudget)
    }

    /// Drop any fragment (line) of the assembled context that is essentially the
    /// user's in-progress text, as a belt-and-suspenders guard on top of the
    /// resolver's focused-subtree pruning. A line is dropped when its normalized
    /// form is contained in the preceding tail, or (for a substantial preceding
    /// tail) contains it. Conservative length floors avoid dropping unrelated
    /// short lines on incidental substring matches.
    static func removingOverlap(_ context: String, with precedingText: String) -> String {
        let precedingKey = normalizedKey(precedingText)
        guard !precedingKey.isEmpty else { return context }

        let lines = context.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { line in
            let key = normalizedKey(line)
            if key.isEmpty { return true }
            if key.count >= 8, precedingKey.contains(key) { return false }
            if precedingKey.count >= 12, key.contains(precedingKey) { return false }
            return true
        }
        return kept.joined(separator: "\n")
    }

    // MARK: - Spatial proximity (doc 06)

    /// A surrounding text node counts as "near" the composer only if it shares
    /// at least this fraction of its own width with the composer's column. Keeps
    /// the conversation/thread in the same column while dropping a main view that
    /// sits beside a narrow side-chat. Modest so an indented message that merely
    /// starts offset still qualifies.
    static let minHorizontalOverlapFraction: CGFloat = 0.30
    /// Vertical reach ABOVE the composer, in multiples of the composer's own
    /// height (scale-free across a tall task description and a short chat
    /// composer). The relevant content lives above the composer — the thread
    /// being replied to, a task's description and comments. Generous on purpose:
    /// the must-not-regress ClickUp task panel puts a tall description well above
    /// a short comment box, so under-reaching would clip it. The horizontal-column
    /// overlap (below) is what excludes a main view beside a narrow side-chat;
    /// this vertical bound mainly drops a distant feed under an inline reply box.
    /// Primary tuning dial — validate against a real long-description task.
    static let verticalWindowAboveFactor: CGFloat = 8.0
    /// Vertical reach BELOW the composer, in multiples of its height. Small —
    /// just enough for a trailing label, not a whole feed beneath a reply box.
    static let verticalWindowBelowFactor: CGFloat = 2.0

    /// Fraction of `candidate`'s width that overlaps `composer`'s horizontal
    /// extent (intersection width / candidate width). 1.0 when `candidate` is
    /// fully inside the composer's column, 0 when disjoint. Zero-width candidate
    /// returns 0. Pure geometry; coordinate convention is irrelevant for x.
    static func horizontalOverlapFraction(_ candidate: CGRect, _ composer: CGRect) -> CGFloat {
        let width = candidate.width
        guard width > 0 else { return 0 }
        let left = max(candidate.minX, composer.minX)
        let right = min(candidate.maxX, composer.maxX)
        let overlap = right - left
        guard overlap > 0 else { return 0 }
        return overlap / width
    }

    /// Whether a surrounding text node at `candidate` is spatially related to the
    /// `composer` the user is typing in: it shares the composer's column
    /// (horizontal overlap ≥ `minHorizontalOverlapFraction`) AND falls within the
    /// bounded vertical window around the composer.
    ///
    /// AX frames are top-left origin / y-down, so "above the composer" means a
    /// SMALLER y. The window is `[composer.minY - above*h, composer.maxY +
    /// below*h]` where `h` is the composer height; a candidate is inside when its
    /// vertical extent intersects that band.
    ///
    /// An empty / zero-area `candidate` (a node with no usable frame) returns
    /// `true`: we cannot localize it, so we don't over-filter — the node-visit
    /// cap and dedup still bound it. An empty `composer` also returns `true`
    /// (filter effectively disabled).
    static func isSpatiallyRelated(candidate: CGRect, composer: CGRect) -> Bool {
        if composer.isEmpty { return true }
        if candidate.isEmpty { return true }

        guard horizontalOverlapFraction(candidate, composer) >= minHorizontalOverlapFraction else {
            return false
        }

        let h = composer.height
        let topLimit = composer.minY - verticalWindowAboveFactor * h     // furthest above (smallest y)
        let bottomLimit = composer.maxY + verticalWindowBelowFactor * h  // furthest below (largest y)
        // Candidate's vertical extent must intersect the [topLimit, bottomLimit] band.
        return candidate.maxY >= topLimit && candidate.minY <= bottomLimit
    }

    // MARK: - Private

    /// Keep the first `limit` characters (the head). Short text passes through.
    private static func cappedToHead(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end])
    }

    /// Lowercased, whitespace-collapsed, trimmed key used for dedup and overlap
    /// comparison only — never for output (the original casing is preserved).
    private static func normalizedKey(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }
}
