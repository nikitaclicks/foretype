import Foundation

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

        setState(.debouncing)
        let ms = settings.current.clamped().debounceMilliseconds
        work.scheduleDebounce(ms: ms) { [weak self] in
            self?.beginGeneration()
        }
    }

    /// Fired when the debounce settles with no newer mutation. Mints a freshness
    /// token, snapshots focus, builds the request, and launches the engine call.
    func beginGeneration() {
        guard let snapshot = focus.current else {
            reevaluateAvailability()
            return
        }

        // Mint a fresh token bound to this snapshot's identity + content.
        generation &+= 1
        let token = generation
        pendingSnapshot = snapshot

        let request = PromptBuilder.build(
            snapshot: snapshot,
            settings: settings.current,
            generation: token
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
}
