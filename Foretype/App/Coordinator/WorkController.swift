import Foundation

/// Owns the two pieces of cancellable work the coordinator juggles: a pending
/// **debounce** timer and the **current generation** task (doc 05, "Debounce and
/// work ownership"). Keeping this bookkeeping in one small object keeps the
/// coordinator's branching logic clean and guarantees that scheduling new work
/// always cancels whatever it supersedes.
@MainActor
final class WorkController {
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?

    init() {}

    /// (Re)start the debounce. Any previously pending debounce is cancelled, so
    /// rapid typing collapses to a single fire after the window settles. `body`
    /// runs on the main actor once the window elapses without interruption.
    func scheduleDebounce(ms: Int, _ body: @escaping () -> Void) {
        debounceTask?.cancel()
        let nanos = UInt64(max(0, ms)) * 1_000_000
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            body()
        }
    }

    /// Start a fresh generation task, cancelling any prior one first so only the
    /// latest cycle can win (the late one also fails the freshness check).
    func startGeneration(_ op: @escaping () async -> Void) {
        generationTask?.cancel()
        generationTask = Task { @MainActor in
            await op()
        }
    }

    /// Cancel both pending debounce and in-flight generation. Called on every
    /// path that abandons a completion (doc 05, "Cancellation discipline").
    func cancelAll() {
        debounceTask?.cancel()
        debounceTask = nil
        generationTask?.cancel()
        generationTask = nil
    }
}
