# 09 — Accepting and Inserting Text

When the user presses `Tab`, Foretype inserts the next chunk of the active
session into the focused field. Insertion must work across arbitrary apps and
must not trigger a feedback loop with the keyboard tap.

## TextInserter

`TextInserter` inserts text by **synthesizing keyboard events**, not by writing
the field's Accessibility value.

- Build a key event pair using `CGEvent(keyboardEventSource:virtualKey:keyDown:)`
  and set its Unicode payload with `keyboardSetUnicodeString(...)`, then post the
  event(s) to `.cghidEventTap`.
- Strip carriage returns from the text before posting.
- Return success/failure; the coordinator reacts (on failure, clear the session
  and hide ghost text).

### Why synthetic events, not AX `setValue`

Writing `AXValue` directly is fragile and inconsistent: many apps ignore it,
mis-handle the caret afterward, or reject it on web content. Synthesized
keyboard input is what the field already expects and works in nearly every
standard text control, including web editors. The cost is the feedback-loop
risk, which `SyntheticInputGuard` handles.

## Suppression handshake (no feedback loop)

Synthetic key events would re-enter `KeyboardTap` and look like the user typing,
triggering a new prediction for text Foretype just inserted. To prevent this:

1. Before posting, the inserter registers the **count** of synthetic key-down
   events with `SyntheticInputGuard` (doc 04).
2. The tap consults the guard and swallows those events from the classification
   path (they become `ignored`), decrementing the expected count.
3. The guard self-clears via count-reaching-zero and/or a short time window, so
   a missed match can never suppress genuine keystrokes indefinitely.

Count-based (not boolean) suppression is required so multi-character chunks are
fully accounted for and a real keystroke landing mid-insertion is not swallowed.

## Acceptance flow

```
Tab pressed
  → KeyboardTap: is a completion visibly acceptable?  ── no ──▶ pass Tab through (normal Tab behavior)
       │ yes
       ▼ consume the Tab (return nil from tap), forward `accept` to coordinator
  CompletionCoordinator (+Acceptance), main actor:
    validate: permission ok, focus supported, state == previewing(session)
       │
       ▼ SessionReconciler.nextChunk(session) → the next word + boundary
    SyntheticInputGuard.expect(chunk synthetic key count)
    TextInserter.insert(chunk)
       │ success                                   │ failure
       ▼                                            ▼
    advance session.consumedCount by chunk      clear session, hide ghost text,
    remainder empty/whitespace? ─ yes ─▶ end → idle, hide      state = failed(reason)
       │ no
       ▼
    predict new caret (doc 08), reposition ghost text to remainder
    request early focus refresh to confirm caret
```

## Chunking

The chunk boundary is decided by the pure `SessionReconciler` (doc 05):

- A chunk is the **next word plus its trailing boundary** (the following space
  or punctuation), so each `Tab` commits a natural unit and the remaining ghost
  text starts cleanly at the next word.
- If the remainder is a single trailing word with no boundary, the whole
  remainder is the final chunk and accepting it exhausts the session.

Word-by-word acceptance lets the user take exactly as much as they want and
keeps the model's longer guess available without another round-trip.

## Edge cases

- **Insertion rejected by the host** (some terminals, games, or sandboxed
  fields ignore synthetic Unicode events): the inserter returns failure; the
  coordinator clears the session and records the reason. Do not retry in a loop.
- **Focus changed between Tab and insertion** (rare, but possible): the
  validate step re-checks focus identity; if it changed, abort the insertion and
  end the session.
- **Secure field:** impossible to reach here (secure fields never produce a
  session), but the validate step still refuses defensively.

## Invariants

- Accepted text is inserted via synthetic events bracketed by
  `SyntheticInputGuard`; the resulting events never trigger a new prediction.
- One `Tab` commits exactly one chunk; the session advances deterministically.
- Insertion failure is surfaced (state + log), never silently retried.
- Insertion and all state mutation happen on the main actor; only the engine
  call is off-main.
