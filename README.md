# Foretype

Foretype is a macOS menu bar app that provides **on-device-aware inline
autocomplete in any text field**. It watches which text field is focused
through Accessibility, observes typing through a global keyboard tap, asks a
language model for a short continuation, renders that continuation as **ghost
text** next to the caret, and inserts it when the user presses `Tab`.

It runs as a lightweight background agent (no dock icon, no main window). It
supports two completion backends:

- **Apple Intelligence** — the on-device system language model (Foundation
  Models framework), private and offline.
- **OpenAI-compatible HTTP** — any endpoint that speaks the
  `/v1/chat/completions` contract (local servers like Ollama / MLX, or remote
  providers).

This repository currently contains **specifications only**. The `docs/` folder
is the source of truth for the intended product and architecture; an
implementing agent should read it in order before writing code.

## Reading order

1. [`docs/00-overview.md`](docs/00-overview.md) — what it is, goals, non-goals, principles
2. [`docs/01-architecture.md`](docs/01-architecture.md) — module map, lifecycle, threading model
3. [`docs/02-permissions.md`](docs/02-permissions.md) — Accessibility + Input Monitoring
4. [`docs/03-focus-and-geometry.md`](docs/03-focus-and-geometry.md) — focus tracking and caret geometry
5. [`docs/04-input-monitoring.md`](docs/04-input-monitoring.md) — keyboard tap and event classification
6. [`docs/05-completion-lifecycle.md`](docs/05-completion-lifecycle.md) — the completion state machine
7. [`docs/06-context-and-prompt.md`](docs/06-context-and-prompt.md) — context gathering and prompt construction
8. [`docs/07-engines.md`](docs/07-engines.md) — engine contract, Apple Intelligence, OpenAI, routing
9. [`docs/08-overlay-rendering.md`](docs/08-overlay-rendering.md) — ghost text overlay
10. [`docs/09-insertion.md`](docs/09-insertion.md) — accepting and inserting text
11. [`docs/10-settings.md`](docs/10-settings.md) — settings model and storage
12. [`docs/11-data-model.md`](docs/11-data-model.md) — value types and protocol contracts
13. [`docs/12-project-and-build.md`](docs/12-project-and-build.md) — Xcode project, targets, build/test
14. [`docs/13-glossary.md`](docs/13-glossary.md) — shared vocabulary
15. [`docs/14-implementation-roadmap.md`](docs/14-implementation-roadmap.md) — suggested build order
16. [`docs/15-implementer-guide.md`](docs/15-implementer-guide.md) — bootstrap, verification, definition of done

For a fresh agent pointed at this repo, [`AGENTS.md`](AGENTS.md) is the entry
point: orientation, hard invariants, and the reading order above.

## At a glance

- **Platform:** macOS (Apple Silicon), SwiftUI + AppKit, agent app (`LSUIElement`).
- **Permissions:** Accessibility and Input Monitoring. No Screen Recording.
- **Dependencies:** none beyond Apple frameworks. No third-party packages.
- **Accept gesture:** `Tab` accepts the next word/chunk; the rest stays as ghost text.
