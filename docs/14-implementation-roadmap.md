# 14 — Implementation Roadmap

A suggested build order for an implementing agent. Each milestone is independently
demonstrable and leaves the app in a runnable state. Build pure rules with tests
*before* the services that use them. Do not start a milestone before the prior
one runs.

## M0 — Project skeleton

- Create the Xcode app target (`LSUIElement`, no third-party deps) and the test
  target per doc 12.
- `ForetypeApp` with a `MenuBarExtra` showing a static label; `AppDelegate`
  retaining an empty `AppEnvironment`.
- Define the `Models/` value types and protocol contracts (doc 11) as compiling
  stubs.
- **Demo:** app launches, shows a menu bar item, no Dock icon.

## M1 — Permissions and menu bar status

- `PermissionMonitor` (poll Accessibility + Input Monitoring, publish changes).
- Menu bar surfaces grant status with "Enable…" actions; first-run onboarding
  window (doc 02).
- **Demo:** menu bar reflects real permission state; granting in System Settings
  updates it within a poll interval.

## M2 — Focus tracking and geometry (read-only)

- `AccessibilityBridge`, `FocusResolver`, `CaretGeometryResolver`, `FocusWatcher`
  (doc 03). Publish `FocusSnapshot`s.
- A temporary debug readout (e.g. in the menu) showing the current snapshot:
  app, role, preceding-text tail, caret rect, quality, capability.
- **Demo:** focus a text field in various apps; observe correct text/selection
  and a caret rect with a sensible quality rating; secure fields report
  `blocked`.

## M3 — Pure rules + tests

- Implement and unit-test, with no UI/AX wired in: context windowing,
  `PromptBuilder`, `CompletionTextNormalizer`, `AvailabilityEvaluator`,
  `AppRuleEvaluator`, `SessionReconciler` (docs 05–10).
- **Demo:** `xcodebuild ... test` green; these tests are the backbone and should
  stay green forever after.

## M4 — OpenAI engine end-to-end (no overlay yet)

- `OpenAIEngine` + a minimal `EngineRouter` (doc 07). `SettingsStore` +
  `KeychainStore` enough to hold a base URL / model / key (doc 10).
- Wire a throwaway command (menu action) that builds a request from the current
  snapshot, calls the engine, and logs the normalized result.
- **Demo:** with a local server (e.g. an Ollama/MLX endpoint) running, focus a
  field, trigger the action, see a sensible completion in the log.

## M5 — Keyboard tap and the completion loop (no acceptance yet)

- `KeyboardTap` + `InputClassifier` (doc 04), forwarding `InputEvent`s.
- `CompletionCoordinator` core + `+Input` + `+Generation`: debounce, generation
  token, freshness checks, cancellation (doc 05).
- Still log instead of rendering, but prove the loop: typing schedules a single
  fresh request; rapid typing cancels older ones; stale results are dropped.
- **Demo:** typing produces exactly one fresh completion per settle; logs show
  stale results discarded.

## M6 — Ghost text overlay

- `GhostTextOverlay` + `GhostTextView` (doc 08): non-activating, click-through,
  positioned at the caret with quality-aware sizing.
- Coordinator `previewing` state shows/hides/repositions the overlay.
- **Demo:** typing shows ghost text at the caret in real apps; it hides on
  navigation/focus change/divergence and never steals focus.

## M7 — Acceptance and insertion

- `TextInserter` + `SyntheticInputGuard` (docs 04, 09); coordinator
  `+Acceptance` with word-by-word chunking and typed-through advance.
- Caret prediction + early focus refresh for smooth repositioning (doc 08).
- **Demo:** `Tab` inserts the next word; remainder stays as ghost text; typing
  matching text advances without a new call; no feedback loop.

## M8 — Apple Intelligence engine

- `AppleIntelligenceEngine` (doc 07), runtime-gated; router selects it; optional
  fallback to OpenAI when configured.
- Settings shows availability and reason when unavailable.
- **Demo:** with the system model available, completions work fully offline,
  no endpoint configured.

## M9 — Settings UI and app rules

- Full `SettingsView` (doc 10): backend pick + test button, length preset, app
  rules, appearance (ghost color, activation indicator), timing.
- Menu bar quick toggles: global on/off and disable-for-current-app.
- **Demo:** every setting takes effect live (in-flight work cancelled,
  availability re-evaluated); per-app block disables completions in that app.

## M10 — Hardening

- Permission revoke/regrant at runtime; tap auto-re-enable after OS disable.
- Backend switch resets engine state and reconfigures the router.
- Broaden host-app coverage only behind the `CaretQuality` gate (doc 03):
  add support where caret resolves to at least `derived`; otherwise stay
  `unsupported` rather than mis-place ghost text.
- **Demo:** the app survives permission churn, endpoint failures, and odd hosts
  without showing a stale or mispositioned completion.

## Ordering principles

- **Pure before impure:** M3's rules underpin M5–M9; get them tested first.
- **Read before write:** focus reading (M2) and the completion loop (M5) precede
  any text insertion (M7).
- **Correctness gates over coverage:** prefer "supported in fewer apps,
  correctly" to "everywhere, sometimes wrong." Expand via the quality gate.
- Keep each service thin enough that the testable layer holds the logic.
