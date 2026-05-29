# 05 — Completion Lifecycle (the state machine)

`CompletionCoordinator` is the single stateful orchestrator. It consumes the
three input streams (focus, keyboard, permissions), drives generation, and emits
ghost text and insertions. It holds little logic itself — it sequences pure
rules and a generation engine, and it enforces the freshness invariant.

To keep it readable, split it across focused extension files that share private
state:

- **Coordinator (core):** dependencies (via protocols), the current state, the
  generation counter, and the active session.
- **+Lifecycle:** start/stop, reacting to settings changes, reacting to
  permission changes, resetting on backend switch.
- **+Input:** handling each `InputEvent` and each new `FocusSnapshot`.
- **+Generation:** debounce, building the request, calling the engine,
  applying or dropping the result.
- **+Acceptance:** Tab handling, session advancement, presenting/repositioning
  ghost text.

## State

```
enum CompletionState: Equatable {
    case idle                          // focused & ready, nothing pending
    case disabled(reason: DisabledReason)
    case debouncing                    // waiting for typing to settle
    case generating                    // engine call in flight
    case previewing(ActiveSession)     // ghost text shown, session active
    case failed(reason: String)        // last generation errored
}

enum DisabledReason: Equatable {
    case permissionMissing
    case fieldUnsupported
    case fieldSecure
    case appDisabledByRule
    case globallyOff
    case backendUnavailable
}
```

The state is observable so the menu bar can show what Foretype is doing.

## The freshness invariant (most important rule)

> A completion is shown **only** if the world it was generated for still
> matches the world now.

Implementation: a monotonically increasing **generation token** (`UInt64`).
A new token is minted whenever a generation request is about to start, and it is
bound to the focus identity (`FocusIdentity.changeSequence`) and the content
state (preceding text) at request time. When the engine returns:

1. Compare the result's generation token to the current token. If not equal → a
   newer request superseded it → **drop silently** (log for debug only).
2. Re-read the live focus snapshot. If identity changed, or preceding text no
   longer ends with what we generated against → **drop**.
3. Otherwise the result is fresh → normalize and present.

This guards against the model finishing after the user has typed more, moved the
caret, switched fields, or switched apps.

## Debounce and work ownership

Rapid typing must not fire a request per keystroke.

- A `textMutation` (or `shortcutMutation`) schedules generation after a
  **debounce** (default ≈ the focus poll interval, configurable). A new mutation
  cancels the pending debounce and restarts it.
- When the debounce fires, the coordinator mints a generation token and starts
  an `async` generation task. A subsequent mutation cancels that task (Swift
  `Task` cancellation) and starts a new cycle.
- Only the latest cycle can win; earlier cycles either are cancelled or fail the
  generation-token check on return.

A small `WorkController` abstraction (pure-ish, holds the pending debounce
deadline and the current task handle) keeps this bookkeeping out of the
branching logic.

## Request preconditions

Before scheduling generation, all must hold (else go/stay `disabled` or `idle`):

- Both permissions granted.
- Global toggle on, and the focused app is not disabled by an app rule
  (`AppRuleEvaluator`, pure — see doc 10).
- Focus snapshot `capability == .supported`, not secure, caret quality at least
  `derived`.
- At least **2 non-whitespace characters** of preceding text (a single
  character is too noisy to complete).

`AvailabilityEvaluator` (pure) folds these inputs into either "may generate" or a
`DisabledReason`, so the coordinator just asks and reacts.

## End-to-end flow

```
textMutation
   → AvailabilityEvaluator: may generate?  ── no ──▶ state = disabled/idle, hide ghost text
        │ yes
        ▼
   state = debouncing ; (re)start debounce timer
        │ (debounce elapses, no newer mutation)
        ▼
   mint generation token g, snapshot focus, PromptBuilder → CompletionRequest
   state = generating ; start Task { engine.generate(request) }
        │
        ▼ (result returns)
   freshness check (token g still current? focus/text still match?) ── stale ──▶ drop
        │ fresh
        ▼
   CompletionTextNormalizer cleans output (strip echo, trim, cap length)
        │ (empty after normalization) ──▶ state = idle, hide
        ▼
   build ActiveSession from normalized text
   state = previewing(session) ; GhostTextOverlay.show(session.remainder, caretGeometry)
```

On engine error: map to `failed(reason)` (transient, logged) or `disabled`
(configuration problem, e.g. bad endpoint / unsupported language) per doc 07,
and hide ghost text.

## The active session and word-by-word acceptance

A completion is not a single accept-all blob. It is an **`ActiveSession`** that
the user consumes incrementally:

```
struct ActiveSession: Equatable {
    let fullText: String        // normalized completion as generated
    var consumedCount: Int      // characters already inserted via Tab / typed-through
    var remainder: String { /* fullText from consumedCount */ }
}
```

Two ways the session advances, both handled by the pure **`SessionReconciler`**:

1. **Tab (accept):** advance `consumedCount` by the **next chunk** — the next
   word plus a trailing space/punctuation boundary. Insert exactly that chunk
   (doc 09). If a remainder is left, keep `previewing` and reposition ghost text
   to the new caret; if only whitespace remains, end the session → `idle`.

2. **Typed-through:** if the user types a character that **matches** the next
   character of `remainder`, advance `consumedCount` by one to skip it (the
   user typed what we were going to suggest) and keep showing the shortened
   remainder — no new model call. If the typed character **diverges** from the
   remainder, the session is invalidated: hide ghost text and start a fresh
   debounce/generation cycle.

`SessionReconciler` is a pure function: `(session, event/typedText) → outcome`
where outcome is one of `advance(n)`, `diverged`, or `exhausted`. All the
fiddly matching logic lives here and is unit-tested without any AX or UI.

## Reacting to focus, settings, permission changes

- **New focus snapshot:** if identity changed, end any active session, hide
  ghost text, and re-evaluate availability for the new field. (Geometry-only
  changes within the same field just reposition ghost text.)
- **Settings change:** cancel in-flight generation, clear the active session,
  hide ghost text, re-evaluate availability. A **backend switch** also asks the
  new engine to reset any per-context state (no-op for stateless engines).
- **Permission lost:** → `disabled(.permissionMissing)`, tear down dependent
  work. **Regained:** re-evaluate on the next snapshot.

## Cancellation discipline

Every path that abandons a completion (newer keystroke, focus change, settings
change, dismiss, permission loss) must: cancel the in-flight generation task,
invalidate any pending debounce, and ensure a late result fails the freshness
check. There must be no way for an abandoned generation to surface ghost text.

## Invariants

- Exactly one active generation cycle at a time; the latest wins.
- No ghost text without a current, fresh `ActiveSession`.
- The state machine is the only writer of `CompletionState`; UI observes.
- All branching logic delegates its decisions to pure rules
  (`AvailabilityEvaluator`, `SessionReconciler`, `AppRuleEvaluator`,
  `PromptBuilder`, `CompletionTextNormalizer`).
