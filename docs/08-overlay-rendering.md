# 08 — Ghost Text Overlay

Ghost text is the faded preview of the pending completion, drawn on screen
immediately after the caret, in any app. It is rendered in a borderless overlay
window that floats above other content and never takes focus.

## GhostTextOverlay

A `GhostTextOverlay` controller owns one reusable overlay window:

- An `NSPanel` configured as a **non-activating** panel
  (`.nonactivatingPanel` style) so showing it never steals key focus from the
  app the user is typing in.
- **Borderless, transparent background, no shadow, no animation.** It is purely
  a text layer.
- **Click-through:** `ignoresMouseEvents = true` — clicks pass to the host app.
- **Always on top, everywhere:** window level above the menu bar (e.g.
  `.statusBar + 1`), collection behavior including `canJoinAllSpaces`,
  `fullScreenAuxiliary`, and `ignoresCycle`, so it follows the user across
  Spaces and survives full-screen apps.
- Content is a SwiftUI `GhostTextView` hosted in a reused `NSHostingView`; on
  update, swap the view's text/geometry rather than rebuilding the hosting view
  (avoids per-update setup cost and flicker).

## What it renders

Only the **remainder** of the active session (the not-yet-consumed text) — see
doc 05. As the user accepts words with `Tab` or types through matching
characters, the overlay is updated with the shorter remainder.

## Geometry and sizing

Positioning is driven by the `CaretGeometry` from the focus snapshot (doc 03):

```
struct OverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect      // Cocoa screen coords
    let fieldRect: CGRect?     // editable field bounds, for wrapping
    let quality: CaretQuality
}
```

- **Position:** left edge at `caretRect.maxX`, vertically aligned to the caret
  line, so the ghost text reads as the natural continuation of the line.
- **Font size:** derive from caret height (e.g. `caretRect.height * ~0.78`),
  clamped to a sane range (≈14–24 pt). With `estimated` caret quality, clamp
  more tightly (≈14–16 pt) since the height is untrustworthy.
- **Color:** the configured ghost-text color (doc 10), a low-emphasis tone that
  reads as "preview, not committed." Default to a system secondary/tertiary
  label color.
- **Overflow / wrapping:** if the remainder would extend past the right screen
  edge, wrap subsequent lines back to the field's left edge (`fieldRect`) so
  long previews stay readable. Keep wrapping simple; do not attempt to mirror
  the host app's exact layout.

## Caret prediction during acceptance

After a `Tab` insertion, the real caret advances, but the next focus poll that
confirms the new caret position is up to one interval away (≈50 ms+, longer in
slow hosts). To avoid a visible jump, the overlay is **repositioned
optimistically** the instant text is inserted:

- Estimate the new caret x by advancing the old caret by
  `insertedChunk.count * charWidth`, where `charWidth` is the snapshot's
  `observedCharWidth` if present, else a measurement from the chosen font.
- Reposition the overlay to that predicted point immediately.
- Also request an **early focus refresh** (doc 03 — `FocusWatcher` can be poked
  to poll now) so the authoritative caret arrives sooner and corrects any
  prediction error.

Prediction is best-effort; if quality is `estimated`, prefer hiding briefly over
showing a confidently-wrong position.

## Lifecycle

- `show(remainder:geometry:)` — lay out, update the hosting view, position the
  panel, and `orderFrontRegardless()` (so it appears without activating).
- `reposition(geometry:)` — move/resize without changing text (used during
  word-by-word acceptance and caret correction).
- `hide(reason:)` — order out and clear; the reason is logged for debugging
  (e.g. "focus changed", "stale result", "user navigated").

The overlay is a dumb renderer: it never decides *whether* to show, only *how*.
All show/hide decisions come from the coordinator.

## Optional caret activation indicator

A small, low-key indicator near the caret may signal "Foretype is active in this
field" even before a completion exists. It follows the same non-activating,
click-through, geometry-driven rules as the ghost text. It is **gated by a
setting** (doc 10, "ghost text appearance") and defaults off if it proves
distracting. Keep it strictly cosmetic — it must never affect the completion
pipeline.

## Invariants

- The overlay never becomes key/main and never accepts mouse or keyboard input.
- It renders only the current session's remainder; nothing persists across
  sessions.
- Positioning trusts `CaretQuality`: degrade gracefully (clamp, or hide) rather
  than place text confidently in the wrong spot.
- All overlay work is on the main actor.
