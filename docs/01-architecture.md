# 01 — Architecture

## Shape of the system

Foretype is a single macOS app target. It is built around one long-lived
**composition root** that constructs every service once at launch and retains
them for the process lifetime. A central **completion coordinator** is the only
stateful orchestrator; it reacts to three input streams (focus changes,
keyboard events, permission changes) and drives one output (ghost text + text
insertion) by consulting pure helper rules and a pluggable generation engine.

```
                         AppEnvironment (composition root)
                                     │ builds + retains
        ┌───────────────┬────────────┼─────────────┬──────────────┐
        ▼               ▼            ▼              ▼              ▼
 PermissionMonitor  FocusWatcher  KeyboardTap  EngineRouter   GhostTextOverlay
        │               │            │              │              ▲
        │ grants         │ snapshots  │ events       │ generate     │ show/hide
        └───────────────┴────────────┴───────┐      │              │
                                              ▼      ▼              │
                                     CompletionCoordinator ─────────┘
                                              │
                                              ├─ uses pure rules:
                                              │    PromptBuilder, CompletionTextNormalizer,
                                              │    AvailabilityEvaluator, AppRuleEvaluator,
                                              │    SessionReconciler
                                              │
                                              └─ commits via TextInserter (+ SyntheticInputGuard)
```

## Layers

The codebase is organized by responsibility, mirroring a layered dependency
rule: **App → UI/Services → Models/Support**. Lower layers never import higher
ones.

- **App/** — process lifecycle and wiring. `ForetypeApp` (SwiftUI `@main`),
  `AppDelegate`, `AppEnvironment` (the composition root), and the
  `CompletionCoordinator` plus its focused extensions. This layer owns object
  lifetime and connects streams; it contains orchestration, not rules.

- **Services/** — the side-effectful boundaries to macOS. Each service wraps a
  fragile or stateful OS facility behind a narrow protocol:
  - `Focus/` — Accessibility focus tracking and caret geometry.
  - `Input/` — the global keyboard tap and synthetic-input suppression.
  - `Engines/` — the generation engines and the router.
  - `Overlay/` — the ghost-text panel.
  - `Insertion/` — synthetic text insertion.
  - `Permission/` — permission state polling and prompts.

- **UI/** — SwiftUI/AppKit presentation: the menu bar content, the settings
  window, and the first-run onboarding flow. UI observes service state; it does
  not construct services.

- **Models/** — shared, immutable value types (`Sendable`, `Equatable`), the
  state-machine enums, the settings snapshot, and the protocol contracts the
  coordinator depends on.

- **Support/** — pure logic. No `UserDefaults`, no Accessibility calls, no
  clock, no network. These are deterministic functions of their inputs and form
  the test backbone.

## Object lifetime and ownership

- `AppEnvironment` is created once and constructs the full dependency graph. It
  is retained by `AppDelegate`. Services are **never recreated** during a
  session; a settings change reconfigures existing services rather than
  rebuilding them.
- SwiftUI views receive the already-built services (via the environment object
  graph) and **observe** their published state. A view must never instantiate a
  service.
- The `CompletionCoordinator` holds its dependencies through the protocol
  contracts in `Models/`, not through concrete service types.

## Threading model

- **Main actor** owns: all UI (SwiftUI/AppKit), the overlay panel, the
  coordinator state machine, and the great majority of Accessibility reads.
  Treat Accessibility and AppKit as main-actor-only.
- **Off the main actor**: only the generation call. Engines perform `async`
  work (an HTTP round-trip, or a Foundation Models request) without blocking
  the UI. Results are hopped back to the main actor before touching coordinator
  state.
- The keyboard tap callback is delivered by Core Graphics on a run-loop the app
  installs; it must do minimal work and forward the event to the main actor for
  handling. The one synchronous decision it makes is whether to **consume** the
  `Tab` key (see `04-input-monitoring.md`).
- Cancellation is explicit and pervasive. Every in-flight generation is owned
  by a task that can be cancelled when the user types again, focus changes, or
  settings change. See `05-completion-lifecycle.md`.

## The three input streams

1. **Focus** — `FocusWatcher` polls the system focus on a timer and publishes a
   `FocusSnapshot` whenever the resolved state changes. The coordinator treats
   focus as eventually consistent.
2. **Keyboard** — `KeyboardTap` (a `CGEventTap`) classifies each key event and
   forwards a semantic `InputEvent`. This is the trigger for requesting,
   advancing, accepting, or dismissing completions.
3. **Permissions** — `PermissionMonitor` polls Accessibility and Input
   Monitoring grant state and publishes changes. Loss of a permission disables
   the relevant stream and surfaces guidance in the menu bar.

## The one output path

The coordinator's only externally visible effects are:

- Asking `GhostTextOverlay` to show or hide ghost text at a caret geometry.
- Asking `TextInserter` to insert accepted text into the focused field,
  bracketed by `SyntheticInputGuard` so the resulting synthetic key events are
  ignored by `KeyboardTap`.

Everything else is internal state and pure computation.

## Why this shape

The hard parts of this product are not the model call — they are: knowing
*where* the caret is across wildly inconsistent host apps, never showing a
completion that no longer matches reality, and inserting text without creating a
feedback loop. Concentrating all timing and correctness logic in one coordinator
(backed by pure, tested rules) keeps those concerns in one place, while the
protocol boundaries keep the macOS-specific fragility quarantined in services
that can be reasoned about and replaced independently.
