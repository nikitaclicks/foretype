# 10 — Settings

Settings are deliberately minimal. The user surface is a small settings window
reachable from the menu bar. Most generation knobs (temperature, top-p, token
budgets) are fixed constants in code, not exposed.

## Settings model

```
struct Settings: Equatable, Sendable {
    // Master controls
    var isEnabled: Bool                 // global on/off
    var appRules: [AppRule]             // per-app allow/block (see below)

    // Backend
    var backend: Backend                // .appleIntelligence | .openAICompatible
    var openAI: OpenAISettings

    // Output shape
    var lengthPreset: LengthPreset      // .short(3–7) | .medium(7–12) | .long(12–20)

    // Timing
    var debounceMilliseconds: Int       // clamped, e.g. 10…500
    var focusPollMilliseconds: Int      // clamped, e.g. 10…500

    // Appearance
    var ghostTextColorHex: String?      // nil → default secondary label color
    var showActivationIndicator: Bool   // the small caret marker (doc 08)
}

enum Backend: String, Codable { case appleIntelligence, openAICompatible }

struct OpenAISettings: Equatable, Sendable {
    var baseURL: String      // e.g. "http://localhost:11434" or a remote host
    var model: String        // e.g. "qwen2.5-coder", "gpt-4o-mini"
    // API key is NOT stored here — see "Storage" below.
}
```

### App rules (per-app enable/disable)

```
struct AppRule: Equatable, Codable, Sendable {
    let bundleID: String
    let mode: Mode            // .block (disable here) | .allow
}
enum Mode: String, Codable { case block, allow }
```

Matching is done by a pure `AppRuleEvaluator`:

- Decide on a single policy and document it. Recommended default policy:
  **allow everywhere except blocked apps** (a blocklist), which matches user
  expectation ("turn it off in this one app"). If you instead support an
  allowlist mode, make the global policy explicit and evaluate rules
  deterministically.
- `AppRuleEvaluator.isEnabled(bundleID:, settings:) -> Bool` is pure and tested;
  the coordinator calls it during availability evaluation (doc 05).

### Length preset

Maps to the `LengthHint` used by `PromptBuilder` (doc 06) and to the `maxTokens`
ceiling. Three presets is enough; keep the labels human ("short / medium /
long" with the word ranges shown).

## Storage

- **`UserDefaults`** holds everything in `Settings` **except** the API key.
  Encode the struct (e.g. as JSON) or store fields individually; either is fine,
  but keep a single `SettingsStore` as the only reader/writer.
- **Keychain** holds the OpenAI **API key**, never `UserDefaults`. A small
  `KeychainStore` wraps add/update/read/delete for one keychain item. The key is
  optional (local servers need none); absence means "send no Authorization
  header."
- `SettingsStore` exposes the current `Settings` as observable state and a typed
  API to mutate each field. It is the single source of truth; services and UI
  read from it, and the coordinator reacts to its changes (doc 05).

## Settings UI

A compact SwiftUI settings window with these sections:

1. **General** — global enable toggle; debounce and poll interval (advanced,
   with sane defaults; can be tucked behind an "Advanced" disclosure).
2. **Backend** — pick Apple Intelligence or OpenAI-compatible.
   - Apple Intelligence: show availability (and, if unavailable, why) instead of
     letting the user pick an unusable backend.
   - OpenAI-compatible: base URL, model name, optional API key (secure field).
     Offer a small set of convenience presets (e.g. a localhost default) but
     keep them as prefilled values, not hidden behavior. A "Test" button that
     does one round-trip and reports success/failure is valuable here.
3. **Completions** — length preset.
4. **Apps** — manage per-app rules (list current rules; add the frontmost app
   quickly; remove).
5. **Appearance** — ghost text color; activation-indicator toggle.

The menu bar (doc 11 / 01) also offers a quick global enable toggle and a way to
disable for the current frontmost app, so common actions don't require opening
settings.

## Reactivity

- Any settings change publishes through `SettingsStore`. The coordinator (doc
  05) cancels in-flight generation, clears the active session, hides ghost text,
  and re-evaluates availability. A **backend switch** additionally calls
  `engine.reset()` and reconfigures the router.
- Interval changes (debounce / poll) are applied to the relevant services
  without rebuilding them.

## Invariants

- The API key lives only in Keychain; nothing else may persist it.
- `SettingsStore` is the only component that reads/writes settings storage.
- App-rule and length-preset interpretation is pure and tested
  (`AppRuleEvaluator`, the preset→hint mapping).
- No setting exposes telemetry, accounts, clipboard, or screen capture
  (all out of scope).
