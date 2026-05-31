import Foundation

/// Acceptance: `Tab` handling, session advancement, ghost-text repositioning
/// (doc 05 "+Acceptance", doc 09 "Acceptance flow").
extension CompletionCoordinator {
    /// Handle an `accept` (Tab). Returns `true` to **consume** the Tab only when a
    /// non-empty chunk is actually inserted; otherwise returns `false` so the Tab
    /// keeps its normal behavior in the host app.
    func handleAccept() -> Bool {
        // Validate: must be previewing an active session.
        guard isPreviewing, let active = session else { return false }

        // Defensive re-check of permissions + focus (doc 09 edge cases).
        guard permissions.accessibilityGranted, permissions.inputMonitoringGranted else {
            return false
        }
        guard let live = focus.current, live.capability == .supported, !live.isSecure else {
            // Focus changed/became unusable between Tab and insertion → abort.
            work.cancelAll()
            endSession(hideReason: "focus changed before accept")
            reevaluateAvailability()
            return false
        }
        // Focus identity must still match the session's field.
        if let issued = pendingSnapshot, issued.identity != live.identity {
            work.cancelAll()
            endSession(hideReason: "focus identity changed before accept")
            reevaluateAvailability()
            return false
        }

        // Compute the chunk to commit.
        let chunk = SessionReconciler.nextChunk(active)
        guard !chunk.isEmpty else { return false }

        // Insert (TextInserter brackets the synthetic events via the guard).
        guard inserter.insert(chunk) else {
            // Insertion rejected by host → surface failure, do not retry.
            session = nil
            pendingSnapshot = nil
            overlay.hide(reason: "insertion failed")
            setState(.failed(reason: "insertion rejected"))
            return false
        }

        // Advance the session by exactly the chunk's character count.
        var advanced = active
        advanced.consumedCount += chunk.count

        if advanced.isExhausted {
            // Nothing meaningful left → end and idle.
            endSession(hideReason: "session exhausted")
            setState(.idle)
            return true
        }

        // Show the shortened remainder at the predicted new caret (doc 08): the
        // consumed chunk must disappear from the bubble, so re-show the new text
        // (reposition would keep the old text). Predict the caret x by the
        // inserted width so it doesn't jump while the next poll confirms.
        session = advanced
        setState(.previewing(advanced))

        if let geometry = predictedGeometry(after: chunk, from: live) {
            overlay.show(advanced.remainder, geometry: geometry)
        }

        // Confirm the real caret with an early focus refresh.
        focus.refreshNow()
        return true
    }

    /// Predict the post-insertion overlay geometry by shifting the caret rect's
    /// origin.x rightward by the inserted chunk's width. Uses the snapshot's
    /// `observedCharWidth` when available, else a fraction of the caret height as
    /// a rough monospace estimate. Returns `nil` if there is no caret to shift.
    func predictedGeometry(after chunk: String, from snapshot: FocusSnapshot) -> OverlayGeometry? {
        guard let caret = snapshot.caret else { return nil }
        let charWidth: CGFloat = caret.observedCharWidth ?? max(1, caret.rect.height * 0.5)
        let dx = CGFloat(chunk.count) * charWidth
        var rect = caret.rect
        rect.origin.x += dx
        return OverlayGeometry(
            caretRect: rect,
            fieldRect: nil,
            quality: caret.quality
        )
    }
}
