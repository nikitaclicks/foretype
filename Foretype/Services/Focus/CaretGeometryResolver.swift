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
    static func resolve(element: AXUIElement, selection: NSRange, fieldRect: CGRect? = nil) -> CaretGeometry? {
        let caret = max(0, selection.location)

        // The host field's font + foreground color at the caret, so the overlay
        // can match family + point size (doc 08) and render in a hue that
        // contrasts the host background. Best-effort: nil for hosts without
        // attributed-string support (some web fields).
        let (font, color) = resolveHostAttributes(element: element, caret: caret)

        // Step 1: zero-length bounds at the caret → exact.
        if let axRect = AccessibilityBridge.boundsForRange(element, location: caret, length: 0),
           isUsableCaretRect(axRect), isCollapsedCaretWidth(axRect),
           let cocoa = AccessibilityBridge.axRectToCocoa(axRect) {
            return logged("1-exact", CaretGeometry(rect: clampToField(normalizedCaretRect(cocoa), field: fieldRect), quality: .exact, observedCharWidth: nil, font: font, color: color), element: element, caret: caret)
        }

        // Step 2: web text-marker bounds → derived. Chromium/WebKit hosts (Chrome,
        // and Electron apps, and rich web editors like ClickUp) frequently return
        // empty / zero-height rects for the NSRange `AXBoundsForRange` above, but
        // expose the caret reliably through `AXSelectedTextMarkerRange` +
        // `AXBoundsForTextMarkerRange`. This is the spec's step 2 (doc 03).
        if let axRect = AccessibilityBridge.boundsForSelectedTextMarkerRange(of: element),
           isUsableCaretRect(axRect), isCollapsedCaretWidth(axRect),
           let cocoa = AccessibilityBridge.axRectToCocoa(axRect) {
            return logged("2-marker", CaretGeometry(rect: clampToField(normalizedCaretRect(cocoa), field: fieldRect), quality: .derived, observedCharWidth: nil, font: font, color: color), element: element, caret: caret)
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
                return logged("3-charbefore", CaretGeometry(
                    rect: clampToField(normalizedCaretRect(cocoa), field: fieldRect),
                    quality: .derived,
                    observedCharWidth: axRect.width > 0 ? axRect.width : nil,
                    font: font,
                    color: color
                ), element: element, caret: caret)
            }
        }

        // Step 4: proportional within DESCENDANT static-text runs → derived. Web
        // rich editors (ClickUp/ProseMirror, etc.) return degenerate rects for
        // both NSRange and collapsed text-marker bounds, but DO expose real frames
        // on the rendered AXStaticText runs (often nested several groups deep). We
        // locate the run containing the caret offset and interpolate within it.
        if let derived = proportionalWithinRuns(element: element, caret: caret, font: font, color: color, fieldRect: fieldRect) {
            return logged("4-runs", derived, element: element, caret: caret)
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
            return logged("5-estimated", CaretGeometry(rect: caretRect, quality: .estimated, observedCharWidth: nil, font: font, color: color), element: element, caret: caret)
        }

        return logged("nil", nil, element: element, caret: caret)
    }

    // MARK: - Font + color

    /// Read the host font and foreground color at the caret, probing the glyph
    /// just before the caret first (it shares the typed run), then the glyph at
    /// the caret, then the field start. Returns the first font found and the
    /// first color found (independently — a probe may yield one but not the
    /// other); both nil when no probe yields anything.
    private static func resolveHostAttributes(element: AXUIElement, caret: Int) -> (CaretFont?, CaretColor?) {
        let probes: [(Int, Int)] = caret > 0 ? [(caret - 1, 1), (caret, 1), (0, 1)] : [(caret, 1), (0, 1)]
        var font: CaretFont?
        var color: CaretColor?
        for (loc, len) in probes {
            guard font == nil || color == nil else { break }
            guard let attrs = AccessibilityBridge.textAttributesForRange(element, location: loc, length: len) else { continue }
            if font == nil, let f = attrs.font {
                font = CaretFont(name: f.name, pointSize: f.pointSize)
            }
            if color == nil, let c = attrs.color {
                color = c
            }
        }
        return (font, color)
    }

    // MARK: - Step 4 helper

    /// Depth-first over DESCENDANT `AXStaticText` runs in document order, find the
    /// run containing the caret offset, and interpolate the caret x proportionally
    /// within that run's real frame. Quality `.derived`. Bounded by a node budget
    /// and a depth cap so a huge document can't stall a poll (we "get out of the
    /// way" — return nil → estimated — rather than walk an unbounded tree).
    private static func proportionalWithinRuns(element: AXUIElement, caret: Int, font: CaretFont?, color: CaretColor?, fieldRect: CGRect?) -> CaretGeometry? {
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
                                rect: clampToField(normalizedCaretRect(cocoa), field: fieldRect),
                                quality: .derived,
                                observedCharWidth: charWidth > 0 ? charWidth : nil,
                                font: font,
                                color: color
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

    /// A collapsed caret (zero-length selection / text-marker range) is a near-zero
    /// -width point. Chromium hosts under re-layout sometimes return the bounds of a
    /// whole line/selection/block instead — a rect hundreds of px wide, frequently at
    /// a transiently-wrong Y (seen in ClickUp's chat composers as `w≈1122` blocks).
    /// Such a rect is not a caret: reject it so a cleaner step (or the next poll)
    /// wins rather than anchoring the overlay to a bogus block.
    private static func isCollapsedCaretWidth(_ rect: CGRect) -> Bool {
        rect.width <= 24
    }

    /// Sanity-bound a caret rect against the field's own frame. The element frame
    /// (AXPosition/AXSize) is far more stable than per-glyph text bounds: some
    /// Chromium hosts (notably ClickUp's portaled chat side-panel composer) return
    /// wildly unstable Y for `AXBoundsForTextMarkerRange`/`AXBoundsForRange`,
    /// jumping between the real caret line and random screen positions for the same
    /// caret offset — which lands the overlay far from the field. A real caret
    /// always lies within its field's box (the field frame grows to enclose all its
    /// text), so when the resolved caret's vertical center falls outside that box
    /// (beyond a small descender/leading slack) the Y is bogus: re-anchor onto the
    /// field's top text line, preserving the caret height and x (clamped into the
    /// field). When no field rect is available this is a no-op.
    private static func clampToField(_ caret: CGRect, field: CGRect?) -> CGRect {
        guard let field, field.height > 0 else { return caret }
        let slack: CGFloat = 6   // descenders, line leading, rounding
        if caret.midY >= field.minY - slack, caret.midY <= field.maxY + slack {
            return caret
        }
        let h = min(caret.height, field.height)
        return CGRect(
            x: min(max(caret.minX, field.minX), field.maxX),
            y: field.maxY - h,            // top text line of the field (largest cocoa y)
            width: caret.width,
            height: h
        )
    }

    /// Ensure a usable, non-zero-width caret rect for positioning the overlay.
    private static func normalizedCaretRect(_ rect: CGRect) -> CGRect {
        var r = rect
        if r.width < 1 { r.size.width = 1 }
        if r.height < 1 { r.size.height = 1 }
        return r
    }

    // MARK: - Diagnostics (caretDiag)

    /// Last winning step and when we logged it, so the 20 Hz poll doesn't flood the
    /// file: we emit on every *change* of winning step and otherwise at most ~2/s.
    private static var diagLastStep: String?
    private static var diagLastLog: ContinuousClock.Instant?

    /// Pass-through that records which strategy won (and the rect/quality it
    /// produced) before returning it. Gated on the `caretDiag` UserDefaults flag
    /// (`defaults write com.foretype.Foretype caretDiag -bool YES`), so a normal run
    /// pays only the unchanged-step early-out. Kept for diagnosing future browser-AX
    /// regressions — e.g. when a Chrome update degrades a web host's caret geometry.
    private static func logged(_ step: String, _ geom: CaretGeometry?, element: AXUIElement, caret: Int) -> CaretGeometry? {
        guard UserDefaults.standard.bool(forKey: "caretDiag") else { return geom }
        let now = ContinuousClock().now
        if step == diagLastStep, let last = diagLastLog, last.duration(to: now) < .milliseconds(500) {
            return geom
        }
        diagLastStep = step
        diagLastLog = now

        let role = AccessibilityBridge.string(element, kAXRoleAttribute) ?? "?"
        let subrole = AccessibilityBridge.string(element, kAXSubroleAttribute) ?? "-"
        let rectStr: String = geom.map {
            String(format: "x=%.0f y=%.0f w=%.1f h=%.1f", $0.rect.origin.x, $0.rect.origin.y, $0.rect.width, $0.rect.height)
        } ?? "nil"
        let quality = geom.map { "\($0.quality)" } ?? "none"
        let line = String(format: "step=%@ quality=%@ caret=%d role=%@|%@ rect=%@\n",
                          step, quality, caret, role, subrole, rectStr)
        guard let data = line.data(using: .utf8) else { return geom }
        let url = URL(fileURLWithPath: "/tmp/foretype-caretdiag.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
        return geom
    }
}
