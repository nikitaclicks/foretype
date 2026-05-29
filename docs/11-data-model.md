# 11 — Data Model and Protocol Contracts

This document collects the shared value types and the protocol boundaries the
coordinator depends on. They live in `Models/`. All value types are `Sendable`
and, where it aids testing, `Equatable`. They are immutable — state transitions
produce new values rather than mutating in place (except small `var` bookkeeping
inside `ActiveSession`).

## Value types

### Focus (doc 03)

```
struct FocusIdentity: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
    let elementHash: Int
    let changeSequence: UInt64
}

enum CaretQuality: Equatable, Sendable { case exact, derived, estimated }

struct CaretGeometry: Equatable, Sendable {
    let rect: CGRect
    let quality: CaretQuality
    let observedCharWidth: CGFloat?
}

enum FocusCapability: Equatable, Sendable {
    case supported
    case blocked(reason: String)
    case unsupported(reason: String)
}

struct FocusSnapshot: Equatable, Sendable {
    let identity: FocusIdentity
    let appName: String
    let role: String
    let subrole: String?
    let precedingText: String
    let trailingText: String
    let selection: NSRange
    let caret: CaretGeometry?
    let isSecure: Bool
    let capability: FocusCapability
}
```

### Completion (docs 05–07)

```
struct CompletionRequest: Equatable, Sendable {
    let generation: UInt64
    let precedingText: String
    let trailingText: String
    let appName: String
    let fieldRole: String
    let lengthHint: LengthHint
    let sampling: SamplingParameters
    let prompt: String
}

struct SamplingParameters: Equatable, Sendable {
    let temperature: Double
    let maxTokens: Int
    let topP: Double
}

enum LengthHint: Equatable, Sendable { case short, medium, long }

struct CompletionResult: Equatable, Sendable {
    let text: String
    let latency: Duration
}

struct ActiveSession: Equatable, Sendable {
    let fullText: String
    var consumedCount: Int
    var remainder: String { /* substring from consumedCount */ }
}

enum CompletionState: Equatable {
    case idle
    case disabled(reason: DisabledReason)
    case debouncing
    case generating
    case previewing(ActiveSession)
    case failed(reason: String)
}

enum DisabledReason: Equatable {
    case permissionMissing, fieldUnsupported, fieldSecure,
         appDisabledByRule, globallyOff, backendUnavailable
}
```

### Overlay (doc 08)

```
struct OverlayGeometry: Equatable, Sendable {
    let caretRect: CGRect
    let fieldRect: CGRect?
    let quality: CaretQuality
}

enum OverlayState: Equatable {
    case hidden(reason: String)
    case visible(text: String, geometry: OverlayGeometry)
}
```

### Input (doc 04)

```
enum InputEvent: Equatable {
    case accept, textMutation, shortcutMutation, navigation, dismiss, ignored
}
```

### Settings (doc 10)

`Settings`, `Backend`, `OpenAISettings`, `AppRule`, `LengthPreset` — defined in
doc 10.

## Protocol contracts

The coordinator depends on **capability-shaped** protocols, not concrete
services. Each concrete service in `Services/` conforms to exactly the protocol
the coordinator needs, and nothing the coordinator imports knows about `AX*`,
`CGEvent`, `NSPanel`, `URLSession`, or `UserDefaults`.

```
protocol PermissionProviding {
    var accessibilityGranted: Bool { get }
    var inputMonitoringGranted: Bool { get }
    var changes: AsyncStream<Void> { get }   // or a Combine publisher
}

protocol FocusProviding {
    var current: FocusSnapshot { get }
    var snapshots: AsyncStream<FocusSnapshot> { get }
    func refreshNow()                         // poke an immediate poll (caret correction)
}

protocol InputObserving {
    /// Forward classified events. Return value tells the tap whether to consume
    /// the key (true only for an accepted Tab).
    var onEvent: ((InputEvent) -> Bool)? { get set }
}

protocol CompletionEngine: Sendable {         // doc 07
    func generate(_ request: CompletionRequest) async throws -> CompletionResult
    func reset() async
}

protocol TextInserting {
    func insert(_ text: String) -> Bool
}

protocol OverlayPresenting {
    func show(_ text: String, geometry: OverlayGeometry)
    func reposition(geometry: OverlayGeometry)
    func hide(reason: String)
}

protocol SettingsProviding {
    var current: Settings { get }
    var changes: AsyncStream<Settings> { get }
}
```

(Choose one async-notification style — `AsyncStream` or Combine — and use it
consistently. The examples above use `AsyncStream`; either is acceptable as long
as it is uniform.)

## Pure rules (in `Support/`)

These are not protocols — they are pure functions/structs with no dependencies,
and they hold the real decision logic:

- **`PromptBuilder`** — `(FocusSnapshot, Settings) -> CompletionRequest`
  (doc 06).
- **`CompletionTextNormalizer`** — `(rawText, request) -> String` (doc 07).
- **`AvailabilityEvaluator`** — `(FocusSnapshot, Settings, permissions) ->
  Either<DisabledReason, GoAhead>` (doc 05).
- **`AppRuleEvaluator`** — `(bundleID, Settings) -> Bool` (doc 10).
- **`SessionReconciler`** — chunking + typed-through reconciliation (doc 05/09):
  `nextChunk(ActiveSession) -> String`,
  `reconcileTyped(ActiveSession, Character) -> Outcome`.
- **Context windowing** — bounding `precedingText`/`trailingText` (doc 06).

## Why this matters

The coordinator becomes a thin sequencer: it observes streams, asks pure rules
what to do, calls the engine, and commands the overlay/inserter. Because every
decision is either a pure function or a protocol call, the entire state machine
can be unit-tested with fakes — no Accessibility, no event tap, no network — and
the macOS-specific fragility stays sealed inside the services.
