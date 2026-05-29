# 13 — Glossary

Shared vocabulary used throughout the specs. Use these terms consistently in
code and comments.

- **Completion** — the short continuation text predicted by the model for the
  caret's position. The core domain noun.

- **Ghost text** — the faded, on-screen rendering of the pending completion's
  remaining (unaccepted) portion, drawn just after the caret.

- **Active session** — a single completion being consumed incrementally. It
  holds the full predicted text and how much has been accepted so far; the user
  advances it word by word (`Tab`) or by typing matching characters.

- **Remainder** — the not-yet-accepted tail of the active session; this is what
  ghost text displays.

- **Chunk** — the unit accepted by one `Tab`: the next word plus its trailing
  boundary (space/punctuation).

- **Typed-through** — when the user types a character that matches the next
  character of the remainder, so the session advances without a new model call.

- **Divergence** — when the user types something that does not match the
  remainder, invalidating the session and triggering a fresh request.

- **Focus snapshot** — an immutable read of the currently focused editable
  field: identity, text around the caret, selection, caret geometry, and
  capability.

- **Focus identity** — what makes a focused field "the same field" across polls:
  bundle id, pid, element hash, and a monotonic change sequence that survives
  hash recycling.

- **Caret geometry** — the caret's on-screen rectangle plus a **quality** rating
  (`exact` / `derived` / `estimated`) signaling how much to trust it.

- **Capability** — whether a field is `supported`, `blocked` (e.g. secure, or
  disabled by an app rule), or `unsupported` (no usable text/geometry).

- **Generation token** — a monotonically increasing number minted per request,
  bound to focus identity and content, used to drop **stale** results.

- **Freshness invariant** — the rule that a completion is shown only if the
  world it was generated for still matches the present world.

- **Debounce** — the short wait after a keystroke before requesting, so rapid
  typing fires one request, not many.

- **Engine** — a component that turns a `CompletionRequest` into completion
  text. Two exist: Apple Intelligence and OpenAI-compatible HTTP.

- **Router** — the engine that selects and delegates to the configured backend.

- **Normalization** — the shared post-processing that cleans raw engine output
  (strip echo/quotes/labels, fix whitespace, cap length) before display.

- **Keyboard tap** — the global `CGEventTap` that observes typing and detects
  the `Tab` accept gesture.

- **Synthetic input guard** — the mechanism that makes the keyboard tap ignore
  the synthetic key events Foretype posts when inserting accepted text, so
  insertion doesn't trigger a new prediction.

- **Overlay** — the borderless, non-activating, click-through `NSPanel` that
  renders ghost text above all apps without taking focus.

- **Agent app** — a menu-bar-only app (`LSUIElement`) with no Dock icon or
  default window.

- **Coordinator** — `CompletionCoordinator`, the single stateful orchestrator
  that sequences pure rules and the engine and enforces invariants.

- **Pure rule** — a dependency-free function/struct in `Support/` holding real
  decision logic (prompt building, normalization, availability, app rules,
  session reconciliation). The test backbone.
