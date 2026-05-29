# 04 — Input Monitoring

Foretype observes typing globally to know when to request, advance, accept, or
dismiss a completion. This is done with a single Core Graphics event tap. The
keyboard tap is the *trigger* side of the system; focus tracking (doc 03) is the
*context* side.

## KeyboardTap

A `KeyboardTap` service wraps one `CGEventTap`:

- Installed at the **session** level, listening for key-down events
  (and the modifier/flags-changed events needed to classify shortcuts).
- Created **only** when Input Monitoring is granted; destroyed when it is
  revoked. It subscribes to `PermissionMonitor` and re-installs on re-grant.
- The tap callback runs on a run loop the service attaches to the main run loop.
  macOS may **disable a tap** if it is slow or after certain system events; the
  service must detect `kCGEventTapDisabledByTimeout` /
  `...DisabledByUserInput` and **re-enable** the tap automatically.

The tap does the minimum synchronously, then forwards a semantic `InputEvent` to
the coordinator on the main actor. The single synchronous decision it makes is
whether to **consume** the event (return `nil` from the callback so the
keystroke does not reach the focused app). It consumes **only** the `Tab` key,
and only when there is a visible completion to accept.

## Classification

Raw key events are mapped to a small semantic vocabulary by a **pure**
`InputClassifier` (testable, no side effects). The coordinator reacts to the
classified kind, never to raw keycodes.

```
enum InputEvent: Equatable {
    case accept              // Tab — accept next word/chunk of the completion
    case textMutation        // a character that changes text → (re)request
    case shortcutMutation    // Cmd/Ctrl combos that likely change text (paste, undo) → re-request
    case navigation          // arrows, home/end, page up/down → dismiss, do not re-request
    case dismiss             // Esc, copy, and other "stop" gestures → dismiss
    case ignored             // everything else
}
```

Mapping guidance:

- **accept** — `Tab` (keycode 48) with no modifiers. This is the accept gesture.
- **textMutation** — letters, digits, space, punctuation, return, delete/
  backspace. These change the field's text, so a new prediction should be
  scheduled (after debounce).
- **shortcutMutation** — `Cmd+V`, `Cmd+Z`, `Cmd+Shift+Z`, `Cmd+X`, select-all,
  etc. Text likely changed; clear the current ghost text and re-request.
- **navigation** — arrow keys, Home/End, Page Up/Down. The caret moved without
  editing; the current completion is no longer valid → dismiss, but do **not**
  request a new one (the user is moving, not typing).
- **dismiss** — `Esc`, `Cmd+C`, and similar. Clear ghost text.
- **ignored** — pure modifier presses, function keys, media keys, etc.

Modifier state must be read from the event flags to distinguish, e.g., a bare
`Tab` (accept) from `Cmd+Tab` (app switch → ignored) and a plain `z`
(textMutation) from `Cmd+Z` (shortcutMutation).

## Why Tab, and consuming it carefully

`Tab` is the accept key. The tap must consume `Tab` **only** when a completion
is currently shown and acceptable; otherwise `Tab` must pass through so it keeps
its normal meaning (focus traversal, indentation). The decision therefore
depends on coordinator state, which the tap reads through a cheap, synchronous
query (e.g. an atomic flag the coordinator keeps updated: "a completion is
visible and acceptable right now"). When that flag is false, the tap returns the
event unmodified.

This split matters: the *consume* decision is synchronous (it must be, to
swallow the key), but the *acceptance work* (inserting text, advancing the
session) is dispatched to the main actor.

## SyntheticInputGuard (suppression)

When Foretype accepts a completion it inserts text by **synthesizing keyboard
events** (see `09-insertion.md`). Those synthetic events would otherwise come
back through `KeyboardTap` as `textMutation` and trigger a new prediction for
text the app just typed — a feedback loop.

`SyntheticInputGuard` breaks the loop:

- Before insertion, the inserter registers with the guard how many synthetic
  key-down events it is about to post.
- The tap consults the guard for each incoming event; matching synthetic events
  are swallowed from the classification path (treated as `ignored`) and the
  expected count is decremented.
- The guard self-clears (count to zero, and/or a short time window) so a missed
  match can't suppress real keystrokes indefinitely.

Track an expected **count** (not just a boolean) so rapid multi-character
insertions are each accounted for and a stray real keystroke during insertion is
not accidentally suppressed.

## Invariants

- The tap exists iff Input Monitoring is granted; it is torn down on revoke and
  auto-re-enabled if macOS disables it.
- Consume `Tab` only when a completion is visibly acceptable; never swallow keys
  otherwise.
- All real text-changing events flow to the coordinator; synthetic insertion
  events do not (guarded).
- The callback is fast and non-blocking; heavy work happens on the main actor
  after forwarding.
