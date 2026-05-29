# 15 — Implementer Guide

This doc is for the agent (or person) implementing Foretype from these specs. It
covers how to bootstrap the project, how to verify each milestone honestly, the
few external facts you must confirm before coding, and what "done" means. Read
it after the rest of `docs/`.

## Project bootstrap (do this first, once)

There is no Xcode project in this repo yet — only specs. Create one before
writing any feature code. The goal of bootstrap is a project that **builds an
empty menu-bar app** and **runs an empty test bundle**, after which you fill in
files per the roadmap.

Requirements for the project you create:

- **App target** named `Foretype`, product type macOS application.
- **Agent app:** set `LSUIElement` (Application is agent) so there is no Dock
  icon and no default window. Prefer a generated Info.plist
  (`GENERATE_INFOPLIST_FILE = YES`) with `INFOPLIST_KEY_LSUIElement = YES` over a
  hand-maintained plist.
- **Deployment target: macOS 14.0**, *not* the Foundation Models OS. This lets
  the OpenAI HTTP backend run on older Macs; the Apple Intelligence engine is
  gated at runtime with `@available` / availability checks (see below). Do not
  raise the deployment target just to import `FoundationModels` — weak-link and
  guard it instead.
- **Not sandboxed.** A tool that reads other apps' Accessibility data and posts
  synthetic key events cannot run under the standard App Sandbox. Do not add the
  App Sandbox entitlement. Plan for Developer-ID-style local signing
  ("Sign to Run Locally" is fine for development).
- **Test target** named `ForetypeTests` using **Swift Testing** (`import
  Testing`), not XCTest. It hosts in the app target (`TEST_HOST` /
  `BUNDLE_LOADER` set, `ENABLE_TESTABILITY = YES` on the app's Debug config) so
  tests can `@testable import Foretype`.
- **A shared scheme** (`Foretype`) committed under
  `Foretype.xcodeproj/xcshareddata/xcschemes/` so `xcodebuild -scheme Foretype`
  works headlessly. Without a shared scheme, command-line builds fail to find
  one.

### Use file-system-synchronized groups

Configure the project so the `Foretype/` and `ForetypeTests/` folders are
**file-system-synchronized groups** (the modern Xcode default). With these, any
`.swift` file you drop into the folder structure on disk is automatically part
of the target — **you never hand-edit `project.pbxproj` to register files.**
This removes the single most common source of project-file friction. Only open
the project in Xcode (or carefully edit the project file) when you need to add a
*target*, a *build setting*, a *capability*, or a *resource bundle* — not for
ordinary source files.

Mirror the folder layout in `docs/12-project-and-build.md` (`App/`, `Services/`,
`UI/`, `Models/`, `Support/`).

### Verify bootstrap before moving on

```bash
xcodebuild -project Foretype.xcodeproj -scheme Foretype \
  -destination 'platform=macOS' build
```

If signing blocks a headless build, append `CODE_SIGNING_ALLOWED=NO` to confirm
the project compiles and is structurally sound, and report the signing issue
separately. Bootstrap is done when this build succeeds and an empty
`ForetypeTests` bundle builds for testing.

## Swift version stance

Start in **Swift 5 language mode** to keep the from-scratch build unblocked. The
`@MainActor` / `Sendable` boundaries described across the specs (docs 01, 11)
are still the intended design and should be annotated as you go. Raising to
Swift 6 strict-concurrency mode later is welcome, but do not let a strict-mode
fight stall feature progress; design to the boundaries first, tighten the
compiler enforcement second.

## What you can verify yourself vs. what needs a human

This is the most important section. Large parts of Foretype touch live macOS
facilities (Accessibility, the event tap, the floating overlay, synthetic
insertion, the system model) that **cannot be self-verified by an autonomous
agent**. You must not claim those work from code inspection or a successful
build. State clearly which checks you ran and which require the human to drive
real apps.

**Agent-verifiable (do these yourself, with tests / builds):**

- Everything in `Support/` — `PromptBuilder`, `CompletionTextNormalizer`,
  `AvailabilityEvaluator`, `AppRuleEvaluator`, `SessionReconciler`, context
  windowing. Unit-test exhaustively.
- `CompletionCoordinator` logic driven by **fakes** for every protocol
  dependency: the freshness invariant (stale results dropped), cancellation on
  new keystrokes / focus change / settings change, the trigger→preview→accept
  state transitions.
- `InputClassifier` keycode/modifier → `InputEvent` mapping.
- The settings round-trip through `SettingsStore` (and that the API key goes to
  Keychain, not `UserDefaults`).
- That the project builds and the test suite passes.

**Human-required (write the code, then ask the human to confirm):**

- `FocusWatcher` / `FocusResolver` / `CaretGeometryResolver`: that focus, text,
  selection, and caret rect are correct in real apps — and degrade to
  `unsupported` rather than mis-resolving.
- `KeyboardTap`: that the tap installs, classifies real typing, consumes `Tab`
  only when a completion is acceptable, and auto-re-enables after the OS
  disables it.
- `GhostTextOverlay`: that ghost text appears at the caret, never steals focus,
  is click-through, and follows Spaces/full-screen.
- `TextInserter` + `SyntheticInputGuard`: that accepted text inserts across apps
  and does not trigger a feedback loop.
- `AppleIntelligenceEngine`: that on-device generation works on a Mac where the
  system model is available.
- The end-to-end feel: latency, no stale/mispositioned completions, word-by-word
  acceptance.

When a milestone's acceptance depends on a human-required check, finish the
code, run every agent-verifiable check around it, then **explicitly hand the
manual verification to the human** with exact steps to try. Do not mark such a
milestone "done" on your own authority.

## External facts to confirm before coding

- **Foundation Models framework.** Before writing `AppleIntelligenceEngine`,
  confirm the current API surface against Apple's official documentation —
  session creation, the request/response call, generation options
  (temperature / token budget), the instructions channel, and the
  model-availability check. Treat any API shape recalled from memory as a guess
  until checked. Keep all of it behind an availability gate so a wrong guess or
  an unsupported machine never blocks the OpenAI path or app launch.
- **OpenAI-compatible contract.** The `/v1/chat/completions` request/response
  shape is stable, but test against a real local server early (M4) so parsing
  and auth-header handling are validated against actual responses.

## Definition of done

Foretype is done when, on a supported Mac:

1. It launches as a menu-bar-only agent (no Dock icon, no window) and guides the
   user to grant **only** Accessibility and Input Monitoring.
2. With a backend configured (Apple Intelligence, or an OpenAI-compatible
   endpoint), typing in a standard text field shows ghost-text completions at
   the caret, without stealing focus.
3. `Tab` accepts the next word/chunk and leaves the remainder as ghost text;
   typing matching text advances the session without a new request; diverging
   text refreshes it.
4. Completions are never shown stale or mispositioned: on uncertain focus,
   unsupported fields, secure fields, or low-quality caret geometry, nothing is
   shown.
5. The user can turn Foretype off globally and per-app, switch backends, and
   change the length preset and appearance — all taking effect live.
6. The `Support/` rules and the coordinator's invariants are covered by a green
   test suite, and the human has confirmed the human-required behaviors above.

Out-of-scope items (doc 00) stay out: no local model runtime, no screen
capture/OCR, no clipboard, no personalization, no telemetry/accounts, no
auto-update machinery, and no third-party dependencies.

## Working norms

- Build the pure rule before the service that uses it; build read paths (focus)
  before write paths (insertion). Follow the roadmap order (doc 14).
- Keep services thin: push real logic into testable `Support/` rules and keep
  macOS fragility sealed behind the protocol contracts in doc 11.
- When in doubt about focus, geometry, permission, or field support — show
  nothing. Correctness-or-nothing beats a confident wrong completion.
- Confirm a `LICENSE` choice with the project owner before publishing; this repo
  ships without one until then.
