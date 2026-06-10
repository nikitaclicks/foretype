import Testing
import Foundation
@testable import Foretype

/// Coordinator behavior tests. These exercise the freshness invariant, debounce
/// cancellation, the trigger→preview happy path, and Tab acceptance — driving the
/// machine entirely through the fakes' streams. All tests are `@MainActor`; we
/// `await` brief yields/sleeps to let the coordinator's background Tasks run.
@MainActor
struct CompletionCoordinatorTests {
    // MARK: Harness

    struct Harness {
        let focus: FakeFocus
        let input: FakeInput
        let permissions: FakePermissions
        let settings: FakeSettings
        let engine: FakeEngine
        let overlay: FakeOverlay
        let inserter: FakeInserter
        let coordinator: CompletionCoordinator
    }

    private func makeHarness(
        engine: FakeEngine = FakeEngine(response: .text("world")),
        debounceMs: Int = 10
    ) -> Harness {
        let focus = FakeFocus()
        let input = FakeInput()
        let permissions = FakePermissions(accessibility: true, inputMonitoring: true)
        var s = Settings.default
        s.debounceMilliseconds = debounceMs
        let settings = FakeSettings(current: s)
        let overlay = FakeOverlay()
        let inserter = FakeInserter()
        let coordinator = CompletionCoordinator(
            focus: focus,
            input: input,
            permissions: permissions,
            settings: settings,
            engine: engine,
            overlay: overlay,
            inserter: inserter
        )
        coordinator.start()
        return Harness(
            focus: focus, input: input, permissions: permissions, settings: settings,
            engine: engine, overlay: overlay, inserter: inserter, coordinator: coordinator
        )
    }

    /// Let queued main-actor Tasks make progress.
    private func tick(_ count: Int = 5) async {
        for _ in 0..<count { await Task.yield() }
    }

    private func sleepMs(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    // MARK: 1. Trigger → preview shows overlay (happy path)

    @Test
    func triggerToPreviewShowsOverlay() async {
        let h = makeHarness()
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        // A keystroke schedules generation.
        h.input.send(.textMutation)
        #expect(h.coordinator.state == .debouncing)

        // Wait past debounce + engine.
        await sleepMs(40)
        await tick()

        #expect(h.engine.generateCount == 1)
        #expect(h.overlay.showCount == 1)
        #expect(h.overlay.lastShownText == "world")
        if case .previewing(let session) = h.coordinator.state {
            #expect(session.fullText == "world")
        } else {
            Issue.record("expected previewing, got \(h.coordinator.state)")
        }
    }

    // MARK: 2. Stale result dropped

    @Test
    func staleResultDropped() async {
        let engine = FakeEngine(response: .text("world"))
        let h = makeHarness(engine: engine)
        h.focus.emit(SnapshotFactory.supported(changeSequence: 1, precedingText: "hello "))
        await tick()

        // While the engine call is in flight, simulate the user typing more by
        // changing the focus identity/content so the freshness re-read fails.
        let focus = h.focus
        engine.setGate {
            await MainActor.run {
                focus.current = SnapshotFactory.supported(
                    changeSequence: 2, precedingText: "hello world more"
                )
            }
        }

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick(10)

        #expect(engine.generateCount == 1)
        // Result generated against the old world must be dropped: no overlay.show.
        #expect(h.overlay.showCount == 0)
    }

    // MARK: 3. Cancellation on a newer keystroke

    @Test
    func newKeystrokeCancelsPriorGeneration() async {
        // Long debounce so two keystrokes collapse to a single generation.
        let h = makeHarness(debounceMs: 60)
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)   // schedules debounce
        await sleepMs(20)             // not yet fired
        h.input.send(.textMutation)   // cancels + reschedules
        #expect(h.engine.generateCount == 0)

        await sleepMs(90)
        await tick()

        // Only the latest cycle runs.
        #expect(h.engine.generateCount == 1)
        #expect(h.overlay.showCount == 1)
    }

    // MARK: 4. Accept inserts nextChunk and updates the bubble to the remainder

    @Test
    func acceptInsertsNextChunkAndShowsRemainder() async {
        let engine = FakeEngine(response: .text("world wide web"))
        let h = makeHarness(engine: engine)
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick()

        // Previewing the full completion.
        #expect(h.overlay.lastShownText == "world wide web")

        // Accept: inserts the first chunk ("world ") and re-shows the shortened
        // remainder (the field anchor doesn't move, so we `show`, not reposition).
        let refreshesBeforeAccept = h.focus.refreshCount
        let consumed = h.input.send(.accept)
        #expect(consumed == true)
        #expect(h.inserter.inserted == ["world "])
        #expect(h.overlay.lastShownText == "wide web")
        // Accept confirms the post-insertion caret with exactly one extra refresh.
        #expect(h.focus.refreshCount == refreshesBeforeAccept + 1)

        if case .previewing(let session) = h.coordinator.state {
            #expect(session.remainder == "wide web")
        } else {
            Issue.record("expected previewing after first accept")
        }
    }

    // MARK: 5. Accept on the final chunk exhausts → idle

    @Test
    func acceptFinalChunkEndsSession() async {
        let engine = FakeEngine(response: .text("world"))
        let h = makeHarness(engine: engine)
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick()
        #expect(h.overlay.lastShownText == "world")

        let consumed = h.input.send(.accept)
        #expect(consumed == true)
        #expect(h.inserter.inserted == ["world"])
        #expect(h.coordinator.state == .idle)
        #expect(h.overlay.hides.isEmpty == false)
    }

    // MARK: 6. Tab with no preview is not consumed

    @Test
    func tabWithoutPreviewPassesThrough() async {
        let h = makeHarness()
        h.focus.emit(SnapshotFactory.supported())
        await tick()

        let consumed = h.input.send(.accept)
        #expect(consumed == false)
        #expect(h.inserter.inserted.isEmpty)
    }

    // MARK: 7. textMutation while previewing hides ghost text + restarts debounce

    @Test
    func mutationWhilePreviewingHidesAndRedebounces() async {
        let h = makeHarness()
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick()
        #expect(h.coordinator.state.isPreviewingState)

        let hidesBefore = h.overlay.hides.count
        h.input.send(.textMutation)
        #expect(h.overlay.hides.count > hidesBefore)
        #expect(h.coordinator.state == .debouncing)
    }

    // MARK: 8. Insertion failure surfaces .failed

    @Test
    func insertionFailureSurfacesFailed() async {
        let engine = FakeEngine(response: .text("world wide"))
        let h = makeHarness(engine: engine)
        h.inserter.shouldSucceed = false
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick()

        let consumed = h.input.send(.accept)
        #expect(consumed == false)
        if case .failed = h.coordinator.state {} else {
            Issue.record("expected failed state, got \(h.coordinator.state)")
        }
    }

    // MARK: 9. unavailable engine error → disabled(.backendUnavailable)

    @Test
    func unavailableErrorDisablesBackend() async {
        let engine = FakeEngine(response: .error(.unavailable(reason: "bad endpoint")))
        let h = makeHarness(engine: engine)
        h.focus.emit(SnapshotFactory.supported(precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        await sleepMs(40)
        await tick()

        #expect(h.coordinator.state == .disabled(reason: .backendUnavailable))
        #expect(h.coordinator.backendAvailable == false)
    }

    // MARK: 10. A same-field focus snapshot must NOT cancel a pending generation
    //
    // Regression for "suggestions only appear after re-focusing the field": a
    // keystroke emits BOTH an InputEvent (schedules the debounce) AND, a poll
    // interval later, a FocusWatcher snapshot reflecting the new text — for the
    // SAME field (identity unchanged). That snapshot must leave the debounce
    // intact, otherwise typing never produces a suggestion until re-focus.
    @Test
    func sameFieldSnapshotDoesNotCancelPendingGeneration() async {
        let h = makeHarness(debounceMs: 40)
        h.focus.emit(SnapshotFactory.supported(changeSequence: 1, precedingText: "hello "))
        await tick()

        // Keystroke schedules the debounce.
        h.input.send(.textMutation)
        #expect(h.coordinator.state == .debouncing)

        // The watcher observes the typed text shortly after, as a SAME-field
        // snapshot (identity unchanged), before the debounce window elapses.
        await sleepMs(15)
        h.focus.emit(SnapshotFactory.supported(changeSequence: 1, precedingText: "hello w"))
        await tick()

        // Still debouncing — the snapshot must not have torn the cycle down.
        #expect(h.coordinator.state == .debouncing)

        // The debounce fires and a suggestion is produced without any re-focus.
        await sleepMs(60)
        await tick()
        #expect(h.engine.generateCount == 1)
        #expect(h.overlay.showCount == 1)
        #expect(h.coordinator.state.isPreviewingState)
    }

    // MARK: 11. A different-field focus snapshot DOES reset the pipeline

    @Test
    func differentFieldSnapshotResetsPipeline() async {
        let h = makeHarness(debounceMs: 40)
        h.focus.emit(SnapshotFactory.supported(changeSequence: 1, precedingText: "hello "))
        await tick()

        h.input.send(.textMutation)
        #expect(h.coordinator.state == .debouncing)

        // Focus jumps to a different field (new identity) before the debounce.
        await sleepMs(10)
        h.focus.emit(SnapshotFactory.supported(changeSequence: 2, precedingText: "other "))
        await tick()

        // The pending cycle is abandoned: no generation fires for the old field.
        await sleepMs(60)
        await tick()
        #expect(h.engine.generateCount == 0)
        #expect(h.overlay.showCount == 0)
    }

    // MARK: 12. A new identity invalidates the surrounding-context cache
    //
    // Regression guard for the cross-tab context leak: the surrounding-context
    // cache is keyed by FocusIdentity, so a genuine field change (e.g. a browser
    // tab switch, which now produces a new identity because the per-tab URL is in
    // the focus signature) must drop the cache. Otherwise Tab A's page context
    // would be reused for a completion typed in Tab B.

    @Test
    func newIdentitySnapshotClearsSurroundingCache() async {
        let h = makeHarness(debounceMs: 40)
        let first = SnapshotFactory.supported(changeSequence: 1, precedingText: "hello ")
        h.focus.emit(first)
        await tick()

        // Seed the cache as if Tab A's surrounding context had been gathered.
        h.coordinator.surroundingContextCache = CompletionCoordinator.SurroundingContextCacheEntry(
            identity: first.identity,
            context: "tab A surrounding context",
            capturedAt: h.coordinator.surroundingClock.now
        )

        // Focus jumps to a different field (new identity) — the tab-switch case.
        h.focus.emit(SnapshotFactory.supported(changeSequence: 2, precedingText: "other "))
        await tick()

        #expect(h.coordinator.surroundingContextCache == nil)
    }
}

private extension CompletionState {
    var isPreviewingState: Bool {
        if case .previewing = self { return true }
        return false
    }
}
