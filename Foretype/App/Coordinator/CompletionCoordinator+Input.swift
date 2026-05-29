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

    /// React to a freshly resolved focus snapshot. An identity change ends the
    /// current session and re-evaluates for the new field; a geometry-only change
    /// within the same field just repositions the ghost text.
    func handleFocusSnapshot(_ snapshot: FocusSnapshot) {
        if session != nil, isPreviewing, let prior = pendingSnapshot,
           prior.identity == snapshot.identity {
            // Same field, still previewing: a geometry-only update → reposition.
            if let geometry = overlayGeometry(for: snapshot) {
                pendingSnapshot = snapshot
                overlay.reposition(geometry: geometry)
            }
            return
        }

        // Identity changed (or no active preview): end session, hide, re-eval.
        work.cancelAll()
        endSession(hideReason: "focus changed")
        reevaluateAvailability()
    }

    // MARK: Geometry helper

    /// Build an `OverlayGeometry` from a snapshot's caret, or `nil` if there is no
    /// usable caret rectangle. Never force-unwraps AX data.
    func overlayGeometry(for snapshot: FocusSnapshot) -> OverlayGeometry? {
        guard let caret = snapshot.caret else { return nil }
        return OverlayGeometry(
            caretRect: caret.rect,
            fieldRect: nil,
            quality: caret.quality
        )
    }
}
