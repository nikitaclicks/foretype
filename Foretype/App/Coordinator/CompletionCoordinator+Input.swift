import Foundation

/// Input handling: react to each classified `InputEvent` and to each new
/// `FocusSnapshot` (doc 05, "+Input").
extension CompletionCoordinator {
    // MARK: InputEvent

    /// Handle one classified keyboard event. Returns `true` only to **consume**
    /// the key — which happens solely for an accepted `Tab` while a non-empty
    /// preview is showing. Every other event is observed and passed through.
    func handleInput(_ event: InputEvent) -> Bool {
        switch event {
        case .accept:
            return handleAccept()

        case .textMutation, .shortcutMutation:
            // SIMPLE typed-through policy (doc 05): if a preview is showing, hide
            // it and restart a debounce; otherwise just (re)debounce. The char is
            // not recoverable from the InputEvent, so we don't drive
            // SessionReconciler.reconcileTyped here.
            // TODO: char-level typed-through via SessionReconciler.reconcileTyped
            //       once a typed Character is plumbed through (e.g. from the next
            //       focus snapshot's precedingText). The reconciler is fully
            //       implemented + tested for the acceptance/typed path.
            if isPreviewing {
                endSession(hideReason: "typed through preview")
            }
            scheduleDebouncedGeneration()
            return false

        case .navigation, .dismiss:
            // Caret moved or the user explicitly dismissed: drop the session.
            work.cancelAll()
            endSession(hideReason: "navigation/dismiss")
            reevaluateAvailability()
            return false

        case .ignored:
            return false
        }
    }

    // MARK: FocusSnapshot

    /// React to a freshly resolved focus snapshot.
    ///
    /// Critically, a snapshot for the *same* field is NOT a trigger to tear down
    /// work: when the user types, the keyboard tap schedules a generation debounce
    /// and then — a poll interval later — the focus watcher publishes a snapshot
    /// reflecting that same typed text. Cancelling here would kill the debounce the
    /// keystroke just scheduled, so typing would never produce a suggestion until
    /// the field was re-focused. Only a genuine focus change (different field) or a
    /// field that has become unusable resets the pipeline.
    func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        let sameField = (lastFocusIdentity == snapshot.identity)
        lastFocusIdentity = snapshot.identity

        // Genuine change of focused field (or the very first focus): abandon the
        // session and any in-flight work, then re-evaluate for the new field. The
        // surrounding-context cache is keyed by identity, so invalidate it here.
        guard sameField else {
            surroundingContextCache = nil
            work.cancelAll()
            endSession(hideReason: "focus changed")
            reevaluateAvailability()
            return
        }

        // Same field, but no longer usable (became secure / unsupported): drop
        // everything and surface the disabled reason.
        guard snapshot.capability == .supported, !snapshot.isSecure else {
            work.cancelAll()
            endSession(hideReason: "field no longer usable")
            reevaluateAvailability()
            return
        }

        // Same usable field, just updated. Leave any pending generation alone. If a
        // preview is on screen, follow the caret / field with a reposition so the
        // ghost text tracks typing-driven caret motion and window drags.
        if isPreviewing, session != nil, let geometry = overlayGeometry(for: snapshot) {
            pendingSnapshot = snapshot
            overlay.reposition(geometry: geometry)
        }
    }

    // MARK: Geometry helper

    /// Build an `OverlayGeometry` for anchoring the ghost text to the focused
    /// field (AX reports the field frame reliably, unlike the caret). The caret
    /// rect is passed through when present for optional refinement, but the field
    /// rect is the anchor. Returns `nil` if there's no field rect to anchor to.
    func overlayGeometry(for snapshot: FocusSnapshot) -> OverlayGeometry? {
        guard let caret = snapshot.caret else { return nil }
        return OverlayGeometry(
            caretRect: caret.rect,
            fieldRect: snapshot.fieldRect,
            quality: caret.quality,
            font: caret.font
        )
    }
}
