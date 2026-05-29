# 06 — Context and Prompt Construction

Foretype completes text using only what it can read from the focused field plus
a little ambient metadata. There is no clipboard scraping, no screen capture,
and no user-profile personalization (all explicitly out of scope, doc 00).

## What goes into a request

```
struct CompletionRequest: Equatable, Sendable {
    let generation: UInt64          // freshness token (doc 05)

    // Context
    let precedingText: String       // bounded text before the caret
    let trailingText: String        // bounded text after the caret (may be empty)
    let appName: String             // e.g. "Safari", "Notes" — light situational hint
    let fieldRole: String           // AX role/subrole, coarse hint (e.g. text area vs. one-line field)

    // Shape of the desired output
    let lengthHint: LengthHint      // see word-count presets
    let sampling: SamplingParameters

    // The fully assembled prompt the engines may use as-is
    let prompt: String
}
```

### Context windowing

`precedingText` and `trailingText` come from the focus snapshot but are
**bounded** before they enter a request, by a pure helper:

- Keep at most ~**1000 characters** and ~**50 words** of `precedingText`,
  retaining the **tail** (closest to the caret). Truncating the head prevents
  far-away stale context from steering the completion and bounds token cost.
- `trailingText` is kept short (a small window) and is optional; it helps the
  model avoid duplicating what already follows the caret. Some hosts won't
  provide it — that's fine.

### Length hint

Maps the user's word-count preset (doc 10) to an instruction and a token budget:

```
enum LengthHint { case short, medium, long }   // e.g. 3–7, 7–12, 12–20 words
```

The hint produces both a natural-language instruction ("Continue with about 3–7
words.") and a `maxTokens` ceiling in `SamplingParameters`.

### Sampling parameters

```
struct SamplingParameters: Equatable, Sendable {
    let temperature: Double    // low default (~0.1–0.3) for stable inline text
    let maxTokens: Int         // derived from LengthHint
    let topP: Double
    // Additional knobs (topK, etc.) are optional and may be ignored by a backend
    // that doesn't support them; engines map what they can.
}
```

Defaults favor determinism — inline autocomplete should be steady, not
creative. These are constants in code, not user-facing settings (keep the
surface frugal); only the word-count preset is user-visible.

## PromptBuilder (pure)

`PromptBuilder` turns a focus snapshot + settings into a `CompletionRequest`. It
is a **pure function**: no `UserDefaults`, no clock, no I/O. It is one of the
most-tested units in the project.

It produces a single canonical `prompt` string that frames the task as inline
continuation, not chat. The framing should make clear to the model that it must:

- Continue the user's text **from the caret**, not restate or rephrase it.
- Return **only the continuation** — no preamble, no quotes, no explanation.
- Respect the length hint.
- Stop at a natural boundary.

A minimal shape (illustrative, not literal):

```
You are an inline autocomplete engine. Continue the user's text naturally.
Return ONLY the continuation text, no quotes or commentary.
Target length: {length instruction}.
Application: {appName}.

Text before caret:
{precedingText}

Text after caret:
{trailingText}

Continuation:
```

Each engine may use this `prompt` directly (the OpenAI engine sends it as a
user/system message pair) or derive a backend-native form from the component
fields (the Apple Intelligence engine uses an instructions channel plus the
prefix). The component fields are always present so engines are not forced to
parse the assembled string.

## Generation gate (where it lives)

The "should we even ask?" decision (doc 05: permissions, app rule, supported
field, ≥2 non-whitespace chars) is **not** in `PromptBuilder`. The builder
assumes it is being called because generation is warranted, and focuses solely
on assembling a good request. Keep the gate in `AvailabilityEvaluator`.

## Invariants

- The prompt is a pure function of (snapshot, settings); identical inputs yield
  an identical prompt (makes it testable and cache-friendly).
- Never include text from a secure field (the snapshot never carries it anyway).
- Context is always windowed to the tail; never send unbounded text.
- No clipboard, no screen text, no personal identifiers in the prompt.
