import AppKit
import ApplicationServices

/// Compute the caret's on-screen rectangle with a `CaretQuality` rating so
/// downstream code knows how much to trust it (doc 03). Tries five strategies in
/// order, stopping at the first success. Correctness-or-nothing: if the caret
/// cannot reach at least `.derived`, the watcher marks the field unsupported.
@MainActor
enum CaretGeometryResolver {

    /// Resolve caret geometry for `element` given its `selection`. Returns nil
    /// when no rect could be obtained at all. All returned rects are in Cocoa
    /// (bottom-left, y-up) screen coordinates and validated to land on a screen.
    static func resolve(element: AXUIElement, selection: NSRange) -> CaretGeometry? {
        let caret = max(0, selection.location)

        // Step 1: zero-length bounds at the caret → exact.
        if let axRect = AccessibilityBridge.boundsForRange(element, location: caret, length: 0),
           isUsableCaretRect(axRect),
           let cocoa = AccessibilityBridge.axRectToCocoa(axRect) {
            return CaretGeometry(rect: normalizedCaretRect(cocoa), quality: .exact, observedCharWidth: nil)
        }

        // Step 2: web text-marker bounds. AXBoundsForTextMarkerRange has no
        // public typed bridge here; we treat the standard NSRange path above as
        // the primary, and rely on character-before (step 3) for web hosts that
        // accept NSRange-style bounds. Left explicit so the ladder is complete.
        // (No additional code: hosts exposing only text-marker bounds without an
        //  NSRange equivalent fall through to step 3/4 or become unsupported.)

        // Step 3: character-before, shifted to its trailing edge → derived.
        if caret > 0,
           let axRect = AccessibilityBridge.boundsForRange(element, location: caret - 1, length: 1),
           isUsableCaretRect(axRect) {
            // Shift to the trailing (right) edge of the preceding glyph.
            let shifted = CGRect(
                x: axRect.origin.x + axRect.width,
                y: axRect.origin.y,
                width: 1,
                height: axRect.height
            )
            if let cocoa = AccessibilityBridge.axRectToCocoa(shifted) {
                return CaretGeometry(
                    rect: normalizedCaretRect(cocoa),
                    quality: .derived,
                    observedCharWidth: axRect.width > 0 ? axRect.width : nil
                )
            }
        }

        // Step 4: proportional within child static-text runs → derived.
        if let derived = proportionalWithinRuns(element: element, caret: caret) {
            return derived
        }

        // Step 5: element-frame fallback → estimated.
        if let frame = AccessibilityBridge.frame(element),
           isUsableCaretRect(frame),
           let cocoa = AccessibilityBridge.axRectToCocoa(frame) {
            // Use the field origin; collapse to a thin caret at the leading edge,
            // top-aligned (AX top-left → after conversion this is the top of the
            // field in Cocoa, i.e. the larger y).
            let caretRect = CGRect(
                x: cocoa.origin.x + 2,
                y: cocoa.origin.y,
                width: 1,
                height: min(cocoa.height, 24)
            )
            return CaretGeometry(rect: caretRect, quality: .estimated, observedCharWidth: nil)
        }

        return nil
    }

    // MARK: - Step 4 helper

    /// Walk AXStaticText children, find the run containing the caret offset, and
    /// estimate the caret x proportionally within that run. Yields an observed
    /// character width. Quality `.derived`.
    private static func proportionalWithinRuns(element: AXUIElement, caret: Int) -> CaretGeometry? {
        let children = AccessibilityBridge.elements(element, kAXChildrenAttribute)
        guard !children.isEmpty else { return nil }

        var consumed = 0
        for child in children {
            guard let role = AccessibilityBridge.string(child, kAXRoleAttribute),
                  role == (kAXStaticTextRole as String) else { continue }
            let runText = AccessibilityBridge.string(child, kAXValueAttribute) ?? ""
            let runLength = runText.utf16.count
            guard runLength > 0 else { continue }

            // Is the caret inside this run?
            if caret >= consumed, caret <= consumed + runLength {
                guard let runAXRect = AccessibilityBridge.frame(child), isUsableCaretRect(runAXRect) else {
                    consumed += runLength
                    continue
                }
                let offsetInRun = caret - consumed
                let fraction = runLength > 0 ? CGFloat(offsetInRun) / CGFloat(runLength) : 0
                let charWidth = runLength > 0 ? runAXRect.width / CGFloat(runLength) : nil
                let caretAXRect = CGRect(
                    x: runAXRect.origin.x + runAXRect.width * fraction,
                    y: runAXRect.origin.y,
                    width: 1,
                    height: runAXRect.height
                )
                if let cocoa = AccessibilityBridge.axRectToCocoa(caretAXRect) {
                    return CaretGeometry(
                        rect: normalizedCaretRect(cocoa),
                        quality: .derived,
                        observedCharWidth: charWidth
                    )
                }
            }
            consumed += runLength
        }
        return nil
    }

    // MARK: - Validation

    /// Reject obviously bogus rects (NaN, zero-size, absurd extents). A
    /// zero-width caret rect is fine; a zero-HEIGHT one is not.
    private static func isUsableCaretRect(_ rect: CGRect) -> Bool {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return false }
        guard rect.height > 0.5, rect.height < 4000 else { return false }
        guard abs(rect.origin.x) < 100_000, abs(rect.origin.y) < 100_000 else { return false }
        return true
    }

    /// Ensure a usable, non-zero-width caret rect for positioning the overlay.
    private static func normalizedCaretRect(_ rect: CGRect) -> CGRect {
        var r = rect
        if r.width < 1 { r.size.width = 1 }
        if r.height < 1 { r.size.height = 1 }
        return r
    }
}
