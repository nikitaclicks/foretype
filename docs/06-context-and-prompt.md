# 06 — Context and Prompt Construction

Foretype completes text using what it can read from the focused field, bounded
read-only content *surrounding* that field (read from the accessibility tree —
e.g. a ClickUp task title, description, or earlier comments), and a little
ambient metadata. There is no clipboard scraping, **no screen capture, and no
OCR** (it is all Accessibility-only), and no user-profile personalization (all
explicitly out of scope, doc 00).

## What goes into a request

```
struct CompletionRequest: Equatable, Sendable {
    let generation: UInt64          // freshness token (doc 05)

    // Context
    let precedingText: String       // bounded text before the caret
    let trailingText: String        // bounded text after the caret (may be empty)
    let appName: String             // e.g. "Safari", "Notes" — light situational hint
    let fieldRole: String           // AX role/subrole, coarse hint (e.g. text area vs. one-line field)
    let surroundingContext: String  // bounded read-only background around the field (may be empty)

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

### Surrounding context

`surroundingContext` is bounded **read-only background** read from the
accessibility tree *around* the focused field — for example earlier messages in
a ClickUp chat thread, or a task's title, description, and comments. It is what
makes a completion relevant to *what is in the app*, not just the field, while
staying Accessibility-only (no screen capture, no OCR).

Unlike `precedingText`/`trailingText`, gathering it is **not pure** — it walks a
bounded slice of the AX tree — so it does not live in `PromptBuilder`. The walk
is done by a `@MainActor` resolver (`SurroundingContextResolver`) and the result
is passed *into* the builder, which only windows it. Key properties:

- **Lazy + cached.** Gathered only at generation time, and cached by the
  coordinator keyed by `FocusIdentity` with a ~5 s TTL, so it is collected about
  once per focused field — never on the 50 ms focus poll, and reused across
  keystrokes within the same field.
- **Scoped, not the whole page.** The resolver climbs to the visually-dominant
  content region (chat thread, task panel, document) by frame-area fraction,
  stopping at the web area, so sidebars / nav / browser chrome are excluded.
  Web composers nest deep, so the climb cap is generous (~20 hops) — a shallow
  cap stops at a sparse sub-wrapper that misses the surrounding messages.
- **Bounded, nearest-first.** Capped by node-visit count, per-fragment chars
  (~240), fragment count (~200), and a total budget (~3000 chars), de-duplicated,
  by a pure helper (`SurroundingContextWindowing`). When over budget it keeps the
  fragments spatially **closest to the composer** (recent replies / the text just
  above the caret), scored by vertical gap — *not* the document-order head, since
  the composer sits at the bottom and the freshest content is last. The web-area
  title is **pinned** (always kept). Survivors are re-emitted in document order so
  the thread stays coherent. (Without a composer frame this collapses to the
  legacy document-order head retention.)
- **Composer-only.** Gathered only for multi-line composer fields (AX text
  areas); single-line search/title boxes get `""` so they don't pull panel noise.
- **Never the focused field's own text.** The focused subtree is pruned during
  the walk, and any fragment overlapping the in-progress `precedingText` is
  removed — so background never duplicates what the user is typing.
- **Never secure.** Secure fields are skipped at the gate and at every node.

In the prompt it is framed as read-only background that the model must **not**
continue, quote, summarize, or repeat, and is placed *before* the caret context
so the text to continue stays last. When empty (the common case for native apps
or non-composer fields) the assembled prompt is byte-identical to before.

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

When `surroundingContext` is non-empty, an additional **read-only background**
section precedes the caret context (and is omitted entirely when empty, keeping
the prompt byte-identical to the no-context case).

A minimal shape (illustrative, not literal):

```
You are an inline autocomplete engine. Continue the user's text naturally.
Return ONLY the continuation text, no quotes or commentary.
Target length: {length instruction}.
Application: {appName}.

[optional, only when present:]
Background context (read-only) ... Do NOT continue, quote, or repeat it.
Surrounding content:
{surroundingContext}

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
- Surrounding context is read-only background, never the continuation target, and
  excludes the focused field's own subtree.
- No clipboard, no screen capture, no OCR, no personal identifiers in the prompt.
