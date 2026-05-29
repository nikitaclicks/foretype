import Foundation

/// Lifecycle wiring: subscribe to the dependency streams, install the keyboard
/// sink, and react to settings / permission changes (doc 05, "Reacting to focus,
/// settings, permission changes").
extension CompletionCoordinator {
    /// Begin orchestrating. Consumes `permissions.changes`, `focus.snapshots`, and
    /// `settings.changes` on background main-actor tasks, installs `input.onEvent`,
    /// and performs an initial availability evaluation.
    func start() {
        // Keyboard sink: classified events arrive here. The closure's Bool return
        // tells the tap whether to consume the key (true only for an accepted Tab).
        input.onEvent = { [weak self] event in
            guard let self else { return false }
            return self.handleInput(event)
        }

        // Focus snapshots.
        let focusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await snapshot in self.focus.snapshots {
                self.handleFocusSnapshot(snapshot)
            }
        }

        // Permission flips: re-evaluate, tear work down if lost.
        let permTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.permissions.changes {
                self.handlePermissionChange()
            }
        }

        // Settings changes: cancel in-flight, clear session, reset backend state.
        let settingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await newSettings in self.settings.changes {
                await self.handleSettingsChange(newSettings)
            }
        }

        streamTasks = [focusTask, permTask, settingsTask]

        reevaluateAvailability()
    }

    /// Stop orchestrating: cancel all work and stream consumers, detach the sink.
    func stop() {
        work.cancelAll()
        for task in streamTasks { task.cancel() }
        streamTasks = []
        input.onEvent = nil
        endSession(hideReason: "stopped")
    }

    // MARK: Reactions

    func handlePermissionChange() {
        if !(permissions.accessibilityGranted && permissions.inputMonitoringGranted) {
            // Permission lost: abandon everything and surface the disabled reason.
            work.cancelAll()
            endSession(hideReason: "permission lost")
            setState(.disabled(reason: .permissionMissing))
            return
        }
        // Regained (or unchanged-but-granted): re-evaluate against current focus.
        reevaluateAvailability()
    }

    func handleSettingsChange(_ newSettings: Settings) async {
        // Any settings change abandons in-flight work and the active session.
        work.cancelAll()
        endSession(hideReason: "settings changed")
        // A backend switch asks the engine to clear per-context state.
        await engine.reset()
        // Optimistically restore backend availability; the next failing call will
        // flip it back. This lets a config fix recover without an app restart.
        backendAvailable = true
        reevaluateAvailability()
    }

    /// Fold current world into a decision and reflect it in `state` when we are
    /// not mid-flight. Never overwrites an active preview/generation with `idle`.
    func reevaluateAvailability() {
        let decision = AvailabilityEvaluator.evaluate(
            snapshot: focus.current,
            settings: settings.current,
            accessibilityGranted: permissions.accessibilityGranted,
            inputMonitoringGranted: permissions.inputMonitoringGranted,
            backendAvailable: backendAvailable
        )

        switch decision {
        case .disabled(let reason):
            // A hard precondition failed: drop any session and show the reason.
            work.cancelAll()
            endSession(hideReason: "unavailable")
            setState(.disabled(reason: reason))
        case .mayGenerate:
            // Ready, but nothing pending. Don't clobber an in-flight cycle.
            switch state {
            case .generating, .previewing, .debouncing:
                break
            default:
                setState(.idle)
            }
        }
    }

    // MARK: Session teardown

    /// End the active session, clear pending work bookkeeping, and hide ghost text.
    func endSession(hideReason: String) {
        session = nil
        pendingSnapshot = nil
        overlay.hide(reason: hideReason)
    }
}
