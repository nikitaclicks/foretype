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

        // Step 2: web text-marker bounds → derived. Chromium/WebKit hosts (Chrome,
        // and Electron apps, and rich web editors like ClickUp) frequently return
        // empty / zero-height rects for the NSRange `AXBoundsForRange` above, but
        // expose the caret reliably through `AXSelectedTextMarkerRange` +
        // `AXBoundsForTextMarkerRange`. This is the spec's step 2 (doc 03).
        if let axRect = AccessibilityBridge.boundsForSelectedTextMarkerRange(of: element),
           isUsableCaretRect(axRect),
           let cocoa = AccessibilityBridge.axRectToCocoa(axRect) {
            return CaretGeometry(rect: normalizedCaretRect(cocoa), quality: .derived, observedCharWidth: nil)
        }

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

        // Step 4: proportional within DESCENDANT static-text runs → derived. Web
        // rich editors (ClickUp/ProseMirror, etc.) return degenerate rects for
        // both NSRange and collapsed text-marker bounds, but DO expose real frames
        // on the rendered AXStaticText runs (often nested several groups deep). We
        // locate the run containing the caret offset and interpolate within it.
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

    /// Depth-first over DESCENDANT `AXStaticText` runs in document order, find the
    /// run containing the caret offset, and interpolate the caret x proportionally
    /// within that run's real frame. Quality `.derived`. Bounded by a node budget
    /// and a depth cap so a huge document can't stall a poll (we "get out of the
    /// way" — return nil → estimated — rather than walk an unbounded tree).
    private static func proportionalWithinRuns(element: AXUIElement, caret: Int) -> CaretGeometry? {
        var consumed = 0
        var budget = 1500
        var result: CaretGeometry?

        func walk(_ node: AXUIElement, _ depth: Int) {
            guard result == nil, depth <= 10, budget > 0 else { return }
            for child in AccessibilityBridge.elements(node, kAXChildrenAttribute) {
                if result != nil || budget <= 0 { return }
                budget -= 1
                let role = AccessibilityBridge.string(child, kAXRoleAttribute)
                if role == (kAXStaticTextRole as String) {
                    let runText = AccessibilityBridge.string(child, kAXValueAttribute) ?? ""
                    let runLength = runText.utf16.count
                    guard runLength > 0 else { continue }
                    // Caret falls within (or at the trailing edge of) this run.
                    if caret >= consumed, caret <= consumed + runLength,
                       let runRect = AccessibilityBridge.frame(child), isUsableCaretRect(runRect) {
                        let offsetInRun = caret - consumed
                        let fraction = CGFloat(offsetInRun) / CGFloat(runLength)
                        let charWidth = runRect.width / CGFloat(runLength)
                        let caretAXRect = CGRect(
                            x: runRect.origin.x + runRect.width * fraction,
                            y: runRect.origin.y,
                            width: 1,
                            height: runRect.height
                        )
                        if let cocoa = AccessibilityBridge.axRectToCocoa(caretAXRect) {
                            result = CaretGeometry(
                                rect: normalizedCaretRect(cocoa),
                                quality: .derived,
                                observedCharWidth: charWidth > 0 ? charWidth : nil
                            )
                            return
                        }
                    }
                    consumed += runLength
                    // Leaf text — do not descend into it.
                } else {
                    walk(child, depth + 1)
                }
            }
        }

        walk(element, 0)
        return result
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
