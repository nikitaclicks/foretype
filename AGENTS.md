# AGENTS.md — Foretype

Orientation for any agent or contributor working in this repository.

## What this repo is

Foretype is a macOS menu bar app that shows **inline autocomplete in any text
field**: it tracks the focused field via Accessibility, watches typing via a
global keyboard tap, asks a language model for a short continuation, renders it
as **ghost text** at the caret, and inserts it word-by-word on `Tab`. Backends:
**Apple Intelligence** (on-device) and **OpenAI-compatible HTTP**.

**This repo currently contains specifications only.** `docs/` is the source of
truth for what to build. There is no Xcode project yet — bootstrapping it is the
first implementation step (see `docs/15-implementer-guide.md`).

## Read the specs in order before coding

1. `docs/00-overview.md` — goals, non-goals, principles
2. `docs/01-architecture.md` — module map, lifecycle, threading
3. `docs/02-permissions.md` → `docs/13-glossary.md` — each subsystem
4. `docs/14-implementation-roadmap.md` — build order (M0–M10)
5. `docs/15-implementer-guide.md` — bootstrap, verification, definition of done

Start at the roadmap's **M0 (project bootstrap)**, which is not yet done.

## Hard rules (do not break these)

- **Two permissions only:** Accessibility and Input Monitoring. Never request
  Screen Recording or anything else. There is no screen capture or OCR.
- **Never read or retain text from a secure field.** Secure fields are blocked
  at focus resolution; nothing downstream may see their contents.
- **Freshness invariant:** a completion is shown only if the focus identity and
  content it was generated against still match the present. Stale results are
  dropped silently. (See `docs/05`.)
- **Get out of the way:** on uncertain focus, unsupported field, low-quality
  caret geometry, or missing permission — show nothing rather than something
  wrong or mispositioned.
- **No third-party dependencies.** Apple frameworks only. No SwiftPM/CocoaPods
  packages, no bundled inference runtime.
- **Out of scope (do not build):** local model runtime, screenshot/OCR/visual
  context, clipboard scraping, prompt personalization, telemetry/accounts,
  auto-update/distribution machinery.

## Architecture in one breath

One composition root (`AppEnvironment`) builds long-lived services once. One
stateful orchestrator (`CompletionCoordinator`) consumes three streams (focus,
keyboard, permissions) and drives two outputs (ghost-text overlay, text
insertion) by calling **pure rules** in `Support/` and a pluggable
`CompletionEngine`. The coordinator depends on capability-shaped **protocols**,
never concrete macOS types — so its logic is testable with fakes. Keep services
thin; keep logic in the pure, tested rules.

## Verify honestly

Much of Foretype touches live macOS facilities that an autonomous agent
**cannot self-verify** (focus/geometry, the event tap, the overlay, synthetic
insertion, the system model). Unit-test the `Support/` rules and the coordinator
with fakes; for the rest, write the code and hand the human exact manual steps.
**Never claim a human-only behavior works from a build alone.** See the
verification matrix in `docs/15-implementer-guide.md`.

## Build & test (after bootstrap)

```bash
xcodebuild -project Foretype.xcodeproj -scheme Foretype \
  -destination 'platform=macOS' build

xcodebuild -project Foretype.xcodeproj -scheme Foretype \
  -destination 'platform=macOS' test
```
