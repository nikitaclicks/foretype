# 07 — Generation Engines

A generation engine turns a `CompletionRequest` into completion text. Foretype
ships **two** engines behind one protocol, plus a router that selects between
them based on settings.

## The contract

```
protocol CompletionEngine: Sendable {
    /// Generate a continuation. Throws CompletionEngineError on failure.
    /// Must support cooperative cancellation (check Task.isCancelled / honor
    /// async cancellation) because the coordinator cancels superseded work.
    func generate(_ request: CompletionRequest) async throws -> CompletionResult

    /// Clear any per-context backend state. No-op for stateless engines.
    func reset() async
}

struct CompletionResult: Equatable, Sendable {
    let text: String        // raw model output, pre-normalization
    let latency: Duration   // measured round-trip, for diagnostics
}

enum CompletionEngineError: Error {
    case unavailable(reason: String)   // configuration / capability problem → coordinator goes `disabled`
    case generationFailed(reason: String) // transient → coordinator goes `failed`
    case cancelled
}
```

The coordinator maps `unavailable` to a `disabled` state (the user must fix
something — bad URL, unsupported language, model not installed) and
`generationFailed` to a transient `failed` state (retry on next keystroke).

Both engines run off the main actor and return raw text; **normalization is
shared and happens in the coordinator**, not in the engines (see below).

## Apple Intelligence engine

Uses the **Foundation Models framework** system language model (on-device,
private, offline). Available only on supported hardware/OS; the engine reports
its own availability so the router and settings UI can reflect it.

- **Availability:** check the framework's model-availability API at startup and
  when settings open. If the system model is unavailable (unsupported device,
  disabled by the user, region/language), surface that in settings and prevent
  selecting this backend (or fall back — see routing).
- **Per-request session:** create a **fresh** model session per request so no
  conversational state accumulates across completions. Inline autocomplete is
  stateless; a long-lived chat session would let earlier fields bleed into later
  ones.
- **Instructions channel:** use the framework's instructions/system facility to
  frame the task as inline continuation (return only the continuation, respect
  length), and pass the prefix as the prompt. Map `SamplingParameters` to the
  framework's generation options (temperature, max tokens) as closely as the API
  allows; ignore knobs it doesn't expose.
- **Errors:** map an unsupported-language/locale error to
  `unavailable(reason:)`. Map transient generation errors to
  `generationFailed`. Map cancellation to `cancelled`.
- **`reset()`** is a no-op (each request already uses a fresh session).

## OpenAI-compatible HTTP engine

Talks to any endpoint implementing `POST {baseURL}/v1/chat/completions`. This
covers local servers (e.g. Ollama, MLX-based servers) and remote providers.

- **Request:** a standard chat-completions JSON body — a `messages` array
  (a system message framing inline autocomplete + a user message carrying the
  prompt/prefix), the configured `model`, `temperature`, `max_tokens`, `top_p`.
  **Non-streaming**: completions are short and round-trip latency dominates, so
  stream handling adds complexity for little gain. Request the full response.
- **Auth:** send `Authorization: Bearer <key>` only if an API key is configured.
  Local servers typically need none, so an empty key omits the header entirely.
- **Timeouts:** generous but bounded — e.g. ~15 s request timeout. A hung
  endpoint must not wedge the pipeline; on timeout, throw `generationFailed`.
- **Parsing:** read `choices[0].message.content` as the completion text. Tolerate
  missing/empty fields by throwing `generationFailed`.
- **Status mapping:**
  - `2xx` → parse and return.
  - `4xx` (esp. 401/403/404) → `unavailable(reason:)` — the user's
    configuration is wrong (bad key, wrong path, unknown model).
  - `5xx` / transport errors / timeout → `generationFailed`.
- **`reset()`** is a no-op (HTTP is stateless per request).
- Use `URLSession` with `async` APIs; honor task cancellation so a superseded
  request is abandoned.

## EngineRouter

`EngineRouter` is itself a `CompletionEngine` that delegates to the engine
selected in settings.

- Reads the selected backend from settings and forwards `generate`/`reset` to
  the matching concrete engine.
- Reconfigures the OpenAI engine when its settings (base URL / model / key)
  change, without rebuilding everything.
- **Optional fallback:** if Apple Intelligence is selected but reports
  `unavailable` for a reason that is *recoverable by another backend* (e.g.
  unsupported language) **and** an OpenAI endpoint is configured, the router may
  fall back to it. If no fallback is configured, propagate `unavailable` so the
  coordinator shows a clear `disabled` reason. Keep this logic explicit and
  small; do not build a complex cascade.

The coordinator only knows `CompletionEngine`; it never branches on backend
type. All backend selection lives in the router.

## Shared text normalization (coordinator-side)

`CompletionTextNormalizer` (pure, in `Support/`) cleans **all** engine output
uniformly before it becomes an `ActiveSession`:

- Strip any echo of the prompt/prefix the model parroted back.
- Strip wrapping quotes, leading labels ("Continuation:"), and stray
  markdown/code fences.
- Remove carriage returns; collapse the result to the kind of short inline text
  the field expects.
- Trim leading whitespace that would double a space already before the caret,
  while preserving an intentional leading space when the caret sits mid-word vs.
  at a word boundary.
- Enforce the length ceiling implied by the `LengthHint` as a final guard.
- If nothing meaningful remains, return empty → coordinator shows no ghost text.

Normalization lives in one place so both engines benefit and behavior is
consistent and testable.

## Invariants

- Engines are stateless across requests (or reset to statelessness via
  `reset()`); no completion may leak context from a previous field.
- Engines never touch the main actor, UI, AX, or settings storage directly —
  they receive a `CompletionRequest` and return a `CompletionResult`.
- All output flows through `CompletionTextNormalizer` before display.
- Configuration errors are `unavailable` (actionable); runtime hiccups are
  `generationFailed` (transient). The distinction drives coordinator state.
