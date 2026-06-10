import Foundation
import ApplicationServices

/// Generation: debounce → mint token → build request → call engine off-main →
/// freshness check → normalize → present or drop (doc 05, "+Generation").
extension CompletionCoordinator {
    /// Schedule (or reschedule) a generation cycle after the debounce window. If
    /// preconditions don't currently hold, reflect that and skip scheduling.
    func scheduleDebouncedGeneration() {
        let decision = AvailabilityEvaluator.evaluate(
            snapshot: focus.current,
            settings: settings.current,
            accessibilityGranted: permissions.accessibilityGranted,
            inputMonitoringGranted: permissions.inputMonitoringGranted,
            backendAvailable: backendAvailable
        )

        guard case .mayGenerate = decision else {
            work.cancelAll()
            endSession(hideReason: "not available")
            if case .disabled(let reason) = decision {
                setState(.disabled(reason: reason))
            }
            return
        }

        // Suppress while the user is typing a bare slash command (e.g. `/help`):
        // the focused app shows its own command picker there, so an inline
        // completion is just noise. Resumes the moment a space follows the command
        // (the user typed the next word). Re-evaluated on every mutation, so this
        // simply holds at idle without flagging the feature as disabled.
        if let snap = focus.current,
           SlashCommandDetector.isCommandInProgress(precedingText: snap.precedingText) {
            work.cancelAll()
            endSession(hideReason: "slash command in progress")
            setState(.idle)
            return
        }

        setState(.debouncing)
        let ms = settings.current.clamped().debounceMilliseconds
        work.scheduleDebounce(ms: ms) { [weak self] in
            self?.beginGeneration()
        }
    }

    /// Fired when the debounce settles with no newer mutation. Mints a freshness
    /// token, snapshots focus, builds the request, and launches the engine call.
    func beginGeneration() {
        // Force a synchronous focus re-read first. `focus.current` is refreshed by
        // a poll timer and can lag up to one interval behind the keystroke that
        // scheduled this cycle; snapshotting it as-is risks building the request
        // against stale preceding text, which then fails the freshness re-check on
        // return and is silently dropped (with nothing to reschedule it). The
        // refresh guarantees we capture the latest typed text.
        focus.refreshNow()

        guard let snapshot = focus.current else {
            reevaluateAvailability()
            return
        }

        // Mint a fresh token bound to this snapshot's identity + content.
        generation &+= 1
        let token = generation
        pendingSnapshot = snapshot

        // Gather read-only surrounding AX content (cached per focus identity) so
        // the completion can be relevant to what's in the app, not just the field.
        let surrounding = surroundingContext(for: snapshot)

        let request = PromptBuilder.build(
            snapshot: snapshot,
            settings: settings.current,
            generation: token,
            surroundingContext: surrounding
        )

        setState(.generating)

        work.startGeneration { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.generate(request)
                self.applyResult(result, request: request, token: token)
            } catch let error as CompletionEngineError {
                self.handleEngineError(error, token: token)
            } catch {
                // Task cancellation surfaces as CancellationError → ignore.
                if error is CancellationError { return }
                self.handleEngineError(.generationFailed(reason: "\(error)"), token: token)
            }
        }
    }

    /// Freshness-check a returning result, then normalize and present, or drop.
    /// Runs on the main actor (the whole coordinator is `@MainActor`).
    func applyResult(_ result: CompletionResult, request: CompletionRequest, token: UInt64) {
        // 1. Token must still be current.
        guard token == generation else { return }

        // 2. Re-read live focus; identity + preceding text must still match.
        guard let live = focus.current,
              let issued = pendingSnapshot,
              live.identity == issued.identity,
              live.precedingText == issued.precedingText else {
            return
        }

        // 3. Normalize the raw output.
        let cleaned = CompletionTextNormalizer.normalize(result.text, request: request)
        guard !cleaned.isEmpty else {
            endSession(hideReason: "empty after normalization")
            setState(.idle)
            return
        }

        // 4. Present.
        let newSession = ActiveSession(fullText: cleaned)
        session = newSession
        pendingSnapshot = live
        setState(.previewing(newSession))

        if let geometry = overlayGeometry(for: live) {
            overlay.show(newSession.remainder, geometry: geometry)
        }
    }

    /// Map an engine error to coordinator state (doc 05 / doc 07). Stale errors
    /// (token no longer current) are dropped.
    func handleEngineError(_ error: CompletionEngineError, token: UInt64) {
        guard token == generation else { return }

        switch error {
        case .cancelled:
            return  // superseded → ignore.
        case .unavailable(let reason):
            backendAvailable = false
            endSession(hideReason: "backend unavailable")
            setState(.disabled(reason: .backendUnavailable))
            _ = reason
        case .generationFailed(let reason):
            endSession(hideReason: "generation failed")
            setState(.failed(reason: reason))
        }
    }

    /// Lazily gather (and cache, per focus identity) the read-only surrounding AX
    /// content for a snapshot (doc 06). Cheap on a cache hit; on a miss it
    /// re-queries the live focused element and walks a bounded slice of the AX
    /// tree via `SurroundingContextResolver`. Returns "" for fields that
    /// shouldn't pull panel context (non-composer, secure, or unsupported), which
    /// makes the assembled prompt byte-identical to the no-context case.
    func surroundingContext(for snapshot: FocusSnapshot) -> String {
        // Only composer-like fields benefit; a search box would just pull in
        // unrelated panel noise.
        guard snapshot.capability == .supported,
              !snapshot.isSecure,
              Self.isContextEligible(role: snapshot.role, subrole: snapshot.subrole) else {
            Self.ctxDiag("gate=BLOCK role=\(snapshot.role) subrole=\(snapshot.subrole ?? "-") cap=\(snapshot.capability) secure=\(snapshot.isSecure)")
            return ""
        }

        // Cache hit: same field, still fresh.
        if let entry = surroundingContextCache,
           entry.identity == snapshot.identity,
           surroundingClock.now - entry.capturedAt <= surroundingContextTTL {
            return entry.context
        }

        // Miss: re-query the live focused element (FocusSnapshot deliberately does
        // not retain the AXUIElement) and walk the tree once.
        guard let focused = AccessibilityBridge.systemFocusedElement(),
              let resolution = FocusResolver.resolve(focused: focused),
              !resolution.isSecure else {
            Self.ctxDiag("gate=PASS but resolution=nil role=\(snapshot.role) subrole=\(snapshot.subrole ?? "-")")
            return ""
        }

        let gathered = SurroundingContextResolver.gather(focusedEditable: resolution.element)
        // Belt-and-suspenders: drop any fragment that is the in-progress text.
        let cleaned = SurroundingContextWindowing.removingOverlap(gathered, with: snapshot.precedingText)

        Self.ctxDiag("gate=PASS role=\(resolution.role) subrole=\(resolution.subrole ?? "-") composerFrame=\(AccessibilityBridge.frame(resolution.element).map { "\($0)" } ?? "nil") gatheredLen=\(gathered.count) cleanedLen=\(cleaned.count) cleaned=<<<\(cleaned.prefix(600))>>>")

        surroundingContextCache = SurroundingContextCacheEntry(
            identity: snapshot.identity,
            context: cleaned,
            capturedAt: surroundingClock.now
        )
        return cleaned
    }

    /// Append a line to `/tmp/foretype-ctxdiag.log`, gated on the `ctxDiag`
    /// UserDefaults flag (like `pollDiag`). Temporary surrounding-context
    /// diagnostics; a normal run pays nothing. Remove once the path is verified.
    static func ctxDiag(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "ctxDiag") else { return }
        guard let data = (message + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/foretype-ctxdiag.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Whether a focused field should pull read-only surrounding context (doc 06).
    /// Composer-like fields benefit; search boxes don't (they'd pull unrelated
    /// panel noise). Multi-line text areas always qualify (the original ClickUp
    /// task-panel case); single-line web composers (Twitter reply, ClickUp
    /// side-chat) report AXTextField/AXComboBox and qualify unless they are
    /// search fields. `FocusResolver` already restricts `role` to these three
    /// editable roles, so anything else is excluded by default.
    static func isContextEligible(role: String, subrole: String?) -> Bool {
        if role == (kAXTextAreaRole as String) { return true }
        if role == (kAXTextFieldRole as String) || role == "AXComboBox" {
            return subrole != (kAXSearchFieldSubrole as String)
        }
        return false
    }
}
