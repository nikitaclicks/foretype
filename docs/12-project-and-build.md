# 12 — Project Setup and Build

## Platform and toolchain

- **OS target:** macOS, Apple Silicon. Choose the minimum deployment target that
  exposes the **Foundation Models framework** (the system on-device model). Set
  the deployment target to the OS version that ships it, and gate the Apple
  Intelligence engine on runtime availability so the app still launches and the
  OpenAI backend still works on machines where the system model is absent.
- **Language:** Swift, with strict concurrency in mind (the `@MainActor` /
  `Sendable` boundaries in docs 01 and 11 are load-bearing — enable concurrency
  checking).
- **UI:** SwiftUI for the menu bar content, settings, and onboarding; AppKit
  (`NSPanel`) for the overlay and any low-level window behavior.

## Dependencies

**None beyond Apple frameworks.** No Swift Package Manager third-party
packages, no CocoaPods. The frameworks used:

- `AppKit`, `SwiftUI` — app shell, windows, overlay, settings.
- `ApplicationServices` / `Accessibility` (`AX*`) — focus and geometry.
- `CoreGraphics` — the event tap and synthetic key events.
- `FoundationModels` — the Apple Intelligence engine (runtime-gated).
- `Foundation` (`URLSession`) — the OpenAI HTTP engine.
- `Security` — Keychain for the API key.

Keeping the dependency set empty is a stated product goal (doc 00); do not add
packages without a compelling, documented reason.

## App configuration

- **Agent app:** set `LSUIElement` (Application is agent) `true` — no Dock icon,
  no default window. The app lives in the menu bar.
- **Info.plist usage strings:** include clear purpose strings for the
  permissions surfaced (Accessibility, Input Monitoring). Do **not** add a
  Screen Recording usage string — the product never captures the screen.
- **App Sandbox:** an inline-autocomplete utility that reads other apps'
  Accessibility data and posts synthetic events generally cannot run under the
  standard App Sandbox. Plan for a non-sandboxed, Developer-ID-style
  distribution model. (Distribution/signing pipeline itself is out of scope for
  the first implementation — doc 00.)
- **Entitlements:** keep minimal; add only what the event tap / AX usage
  requires for local development signing.

## Target layout

A single app target plus a unit-test target.

```
Foretype.xcodeproj
Foretype/
  App/
    ForetypeApp.swift            // @main, MenuBarExtra scene
    AppDelegate.swift            // NSApplicationDelegate, retains AppEnvironment
    AppEnvironment.swift         // composition root
    Coordinator/
      CompletionCoordinator.swift
      CompletionCoordinator+Lifecycle.swift
      CompletionCoordinator+Input.swift
      CompletionCoordinator+Generation.swift
      CompletionCoordinator+Acceptance.swift
  Services/
    Focus/        (FocusWatcher, FocusResolver, CaretGeometryResolver, AccessibilityBridge)
    Input/        (KeyboardTap, InputClassifier, SyntheticInputGuard)
    Engines/      (EngineRouter, AppleIntelligenceEngine, OpenAIEngine)
    Overlay/      (GhostTextOverlay, GhostTextView, ActivationIndicator)
    Insertion/    (TextInserter)
    Permission/   (PermissionMonitor)
    Settings/     (SettingsStore, KeychainStore)
  UI/
    MenuBarView.swift
    SettingsView.swift
    OnboardingView.swift
  Models/         (value types + protocol contracts from doc 11)
  Support/        (PromptBuilder, CompletionTextNormalizer, AvailabilityEvaluator,
                   AppRuleEvaluator, SessionReconciler, ContextWindowing)
ForetypeTests/
  (one test file per pure rule, plus coordinator tests using fakes)
```

The `App/`, `Services/`, `UI/`, `Models/`, `Support/` split mirrors the
dependency rule in doc 01: lower layers never import higher ones.

## What to test (and how)

The pure rules in `Support/` and the value-type transitions are the test
backbone — they need no macOS facilities:

- `PromptBuilder`: identical inputs → identical prompt; windowing applied;
  secure/empty handled.
- `CompletionTextNormalizer`: echo stripping, quote/label stripping, whitespace
  joining at word boundaries, length capping, empty-result handling.
- `AvailabilityEvaluator`: every `DisabledReason` path; the ≥2-non-whitespace
  gate; app-rule and global-toggle interaction.
- `AppRuleEvaluator`: block/allow policy, frontmost-app matching.
- `SessionReconciler`: next-chunk boundaries (word + trailing punctuation/space),
  typed-through advance, divergence, exhaustion.
- `CompletionCoordinator`: drive it with **fake** `FocusProviding`,
  `InputObserving`, `CompletionEngine`, `OverlayPresenting`, `TextInserting`,
  `PermissionProviding`, `SettingsProviding` to assert the freshness invariant
  (stale results dropped), cancellation on new keystrokes/focus changes, and the
  full trigger→preview→accept loop.

The macOS-touching services (`FocusWatcher`, `KeyboardTap`, `GhostTextOverlay`,
`TextInserter`, the two engines) are validated by running the app; keep their
logic thin so most correctness lives in the testable layer.

## Build and validation commands

```bash
# Build the app
xcodebuild -project Foretype.xcodeproj -scheme Foretype \
  -destination 'platform=macOS' build

# Build for testing / run unit tests
xcodebuild -project Foretype.xcodeproj -scheme Foretype \
  -destination 'platform=macOS' test
```

If app-hosted tests fail due to local signing/Team-ID issues, report the exact
failure and still run `build-for-testing` so the pure-rule tests compile.

## A note on registering test files

If the project is created such that the test group does not auto-discover files,
new test files must be added to the test target explicitly in the project file.
Prefer a project configuration where the source and test groups auto-discover
files on disk to avoid this friction.
