import Foundation

/// The single stateful orchestrator of the completion pipeline (doc 05). It
/// consumes the focus / keyboard / permission / settings streams, drives the
/// engine, and emits ghost text and insertions — but holds little logic itself:
/// it sequences the pure rules (`AvailabilityEvaluator`, `PromptBuilder`,
/// `CompletionTextNormalizer`, `SessionReconciler`) and enforces the freshness
/// invariant.
///
/// To stay readable it is split across focused extensions that share this
/// private state:
/// - core (this file): stored deps, `@Published` state, generation counter,
///   active session, the `WorkController`, and `start()`.
/// - `+Lifecycle`: stream consumption, settings / permission reactions.
/// - `+Input`: handling each `InputEvent` and each new `FocusSnapshot`.
/// - `+Generation`: debounce → build → engine → apply/drop.
/// - `+Acceptance`: Tab handling, session advancement, ghost-text positioning.
@MainActor
final class CompletionCoordinator: ObservableObject {
    // MARK: Dependencies (protocols only — never concrete services)

    let focus: FocusProviding
    let input: InputObserving
    let permissions: PermissionProviding
    let settings: SettingsProviding
    let engine: CompletionEngine
    let overlay: OverlayPresenting
    let inserter: TextInserting

    // MARK: Observable state (the coordinator is the only writer)

    @Published private(set) var state: CompletionState = .idle

    // MARK: Private machine state

    /// Monotonic freshness token. A new value is minted before each engine call
    /// and bound to the focus identity + preceding text at request time (doc 05).
    var generation: UInt64 = 0

    /// The completion currently being consumed, if any.
    var session: ActiveSession?

    /// Debounce + generation-task ownership.
    let work = WorkController()

    /// Whether the selected backend is currently usable. Flipped to `false` on a
    /// `.unavailable` engine error and re-evaluated on settings / backend change.
    var backendAvailable = true

    /// The focus snapshot a generation was issued for, captured at request time
    /// so the freshness re-read can compare identity + preceding text on return.
    var pendingSnapshot: FocusSnapshot?

    /// Identity of the field the last focus snapshot referred to. Lets
    /// `handleFocusSnapshot` tell a *real* focus change (new field → reset) apart
    /// from the same field merely updating (text typed, caret moved, window
    /// dragged) — the latter must NOT tear down pending generation work. This is
    /// tracked separately from `pendingSnapshot`/`session` because both are nil
    /// during the first keystrokes, before any cycle has completed.
    var lastFocusIdentity: FocusIdentity?

    /// Background tasks consuming the dependency streams; cancelled on `stop()`.
    var streamTasks: [Task<Void, Never>] = []

    init(
        focus: FocusProviding,
        input: InputObserving,
        permissions: PermissionProviding,
        settings: SettingsProviding,
        engine: CompletionEngine,
        overlay: OverlayPresenting,
        inserter: TextInserting
    ) {
        self.focus = focus
        self.input = input
        self.permissions = permissions
        self.settings = settings
        self.engine = engine
        self.overlay = overlay
        self.inserter = inserter
    }

    // MARK: State writing helpers

    /// The only place `state` is mutated (besides the published property itself).
    func setState(_ new: CompletionState) {
        state = new
    }

    /// Whether a usable session is currently on screen.
    var isPreviewing: Bool {
        if case .previewing = state { return true }
        return false
    }
}
