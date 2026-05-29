# 03 — Focus Tracking and Caret Geometry

This is the hardest subsystem. macOS Accessibility (AX) data is **eventually
consistent, app-specific, and frequently incomplete**. Foretype's correctness
depends on getting two things from the focused field: (a) the text around the
caret and the selection, and (b) the on-screen rectangle of the caret so ghost
text can be positioned. Both are best-effort.

## Design stance: poll, don't subscribe

Focus is tracked by **polling on a timer**, not by subscribing to AX
notifications. AX observer delivery is unreliable and inconsistent across host
apps; a steady poll gives a single, predictable change source with bounded
staleness.

- Default poll interval ≈ **50 ms** (configurable in a sane range, e.g.
  10–500 ms). Each tick re-reads the system-wide focused element and rebuilds a
  snapshot; any stale state self-heals within one interval.
- The watcher publishes a new `FocusSnapshot` only when the resolved snapshot
  meaningfully changes (identity or content/geometry), to avoid churn.

## Pipeline

```
FocusWatcher (timer)
   └─ reads system focused element + frontmost app   (AccessibilityBridge)
        └─ FocusResolver: find the usable editable element + read text/selection
             └─ CaretGeometryResolver: compute caret rect + quality
                  └─ FocusSnapshot (published)
```

### AccessibilityBridge

Low-level Core Foundation bridging, isolated so the rest of the code never
touches raw `AX*` C APIs directly. Responsibilities:

- Get the system-wide focused UI element (`kAXFocusedUIElementAttribute` on the
  system-wide element) and the frontmost application (bundle id, pid, name).
- Read attributes (`AXValue`, `AXRole`, `AXSubrole`, `AXSelectedTextRange`,
  etc.) and parameterized attributes (`AXBoundsForRange`,
  `AXBoundsForTextMarkerRange`).
- Convert between AX screen coordinates (origin top-left, y-down) and Cocoa
  screen coordinates (origin bottom-left, y-up), accounting for multi-display
  arrangements.

All reads are tolerant: a missing attribute is a normal outcome, not an error.

### FocusResolver

Given the raw focused element, find the **most usable editable target** and read
its content. The focused element is often a wrapper, not the editable node, so
the resolver may walk parents/children/siblings looking for a candidate with:

- An editable text role (`AXTextArea`, `AXTextField`, or a web text role), and
- A readable text value and a selection range.

It must **reject**:

- Secure inputs (`AXSubrole == AXSecureTextField`, or protected/password
  fields). No completion work begins for these — ever.
- Elements with no readable text capability.

From the chosen element it reads:

- The full or windowed text value and the selection range.
- The **preceding text** (text before the caret) and **trailing text** (after),
  which become the model context. Only a bounded window is retained
  (see `06-context-and-prompt.md`).

### CaretGeometryResolver

Compute the caret's on-screen rectangle, with a **quality** rating so downstream
code knows how much to trust it. Try in order, stopping at the first success:

1. **Zero-length bounds at caret** — `AXBoundsForRange` for range
   `(selectionStart, 0)`. Most accurate → quality `exact`.
2. **Web text-marker bounds** — for WebKit/Chromium hosts that fail NSRange
   queries, use `AXBoundsForTextMarkerRange` equivalents where available →
   quality `derived`.
3. **Character-before, shifted** — `AXBoundsForRange` for `(selectionStart-1, 1)`
   then shift to the trailing edge → quality `derived`.
4. **Proportional within child text runs** — walk `AXStaticText` children,
   find the run containing the caret, estimate the x-offset proportionally; also
   yields an observed character width → quality `derived`.
5. **Element frame fallback** — use the field's frame origin → quality
   `estimated` (treat as barely trustworthy).

The result carries the rect, the quality, and an optional observed character
width (used later for caret prediction during insertion).

```
enum CaretQuality { case exact, derived, estimated }

struct CaretGeometry {
    let rect: CGRect          // Cocoa screen coordinates
    let quality: CaretQuality
    let observedCharWidth: CGFloat?
}
```

Downstream rule: with `estimated` geometry, clamp overlay font conservatively
and be more willing to suppress ghost text than to mis-place it.

## The focus snapshot

```
struct FocusIdentity: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let elementHash: Int     // CFHash of the element; may recycle
    let changeSequence: UInt64  // monotonic; disambiguates recycled hashes
}

struct FocusSnapshot: Equatable, Sendable {
    let identity: FocusIdentity
    let appName: String
    let role: String
    let subrole: String?
    let precedingText: String   // bounded window before caret
    let trailingText: String    // bounded window after caret
    let selection: NSRange
    let caret: CaretGeometry?
    let isSecure: Bool
    let capability: FocusCapability
}

enum FocusCapability: Equatable {
    case supported
    case blocked(reason: String)      // e.g. secure field, app disabled by rule
    case unsupported(reason: String)  // e.g. no text/selection/geometry available
}
```

- **`changeSequence`** is a monotonically increasing counter incremented on each
  genuine focus change. Because `elementHash` (a `CFHash`) can recycle across
  different elements, the sequence is what guarantees field identity does not
  collide. The completion **generation token** (see `05`) is derived from
  identity + content, so a stale model result is detectable.
- `isSecure` short-circuits everything: a secure field yields
  `capability == .blocked` and no text is read.

## App-specific quirks to expect

These are realities of AX on macOS; the resolver and geometry code must degrade
gracefully through them rather than assume a clean tree.

- **WebKit / Chromium content** exposes text differently from native controls,
  sometimes only through text-marker APIs, and rich editors may mount their
  editable subtree a beat after focus lands — so the first poll may see a
  wrapper and a later poll the real field. The poll loop naturally retries.
- **Out-of-process iframes** (common in web mail/chat) may not expose editable
  nodes through the standard tree at all. Treat as `unsupported` when no usable
  element/geometry is found rather than guessing a wrong caret position.
- **Coordinate flips and multi-display**: always convert AX→Cocoa and validate
  the rect lands on a real screen before using it.

> Note: the original product invested heavily in vendor-specific AX coaxing for
> certain browsers. For Foretype, **prefer correctness-or-nothing**: if a host's
> caret cannot be resolved to at least `derived` quality, mark the field
> `unsupported` and show no ghost text there. Broaden support later only with
> evidence, behind the same `CaretQuality` gate.

## Invariants

- Treat every AX read as possibly-missing; never force-unwrap AX data.
- Never read or retain text from a secure field.
- A snapshot with `capability != .supported` must prevent any generation.
- All AX interaction happens on the main actor.
