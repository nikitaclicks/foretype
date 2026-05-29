import Foundation
@testable import Foretype

// In-test fakes for the seven @MainActor capability protocols the coordinator
// depends on. Each stream-bearing fake exposes a continuation so tests can feed
// snapshots / changes synchronously, and records the calls the coordinator makes.

// MARK: - FakeFocus

@MainActor
final class FakeFocus: FocusProviding {
    var current: FocusSnapshot?
    let snapshots: AsyncStream<FocusSnapshot>
    private let continuation: AsyncStream<FocusSnapshot>.Continuation
    private(set) var refreshCount = 0

    init(current: FocusSnapshot? = nil) {
        self.current = current
        var cont: AsyncStream<FocusSnapshot>.Continuation!
        self.snapshots = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func refreshNow() { refreshCount += 1 }

    /// Push a snapshot to the stream (and update `current`).
    func emit(_ snapshot: FocusSnapshot) {
        current = snapshot
        continuation.yield(snapshot)
    }
}

// MARK: - FakeInput

@MainActor
final class FakeInput: InputObserving {
    var onEvent: ((InputEvent) -> Bool)?

    /// Drive a classified event through the coordinator; returns the consume bool.
    @discardableResult
    func send(_ event: InputEvent) -> Bool {
        onEvent?(event) ?? false
    }
}

// MARK: - FakePermissions

@MainActor
final class FakePermissions: PermissionProviding {
    var accessibilityGranted: Bool
    var inputMonitoringGranted: Bool
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(accessibility: Bool = true, inputMonitoring: Bool = true) {
        self.accessibilityGranted = accessibility
        self.inputMonitoringGranted = inputMonitoring
        var cont: AsyncStream<Void>.Continuation!
        self.changes = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func flip(accessibility: Bool? = nil, inputMonitoring: Bool? = nil) {
        if let accessibility { accessibilityGranted = accessibility }
        if let inputMonitoring { inputMonitoringGranted = inputMonitoring }
        continuation.yield(())
    }
}

// MARK: - FakeSettings

@MainActor
final class FakeSettings: SettingsProviding {
    var current: Settings
    let changes: AsyncStream<Settings>
    private let continuation: AsyncStream<Settings>.Continuation

    init(current: Settings = .default) {
        self.current = current
        var cont: AsyncStream<Settings>.Continuation!
        self.changes = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func update(_ newValue: Settings) {
        current = newValue
        continuation.yield(newValue)
    }
}

// MARK: - FakeEngine

/// Engine fake. `respond` controls what `generate` returns/throws; an optional
/// `gate` lets a test hold the call open until it signals (to inject staleness).
final class FakeEngine: CompletionEngine, @unchecked Sendable {
    enum Response { case text(String); case error(CompletionEngineError) }

    private let lock = NSLock()
    private var _response: Response
    private var _generateCount = 0
    private var _resetCount = 0
    private var _gate: (@Sendable () async -> Void)?

    init(response: Response = .text("world")) {
        self._response = response
    }

    var generateCount: Int { lock.lock(); defer { lock.unlock() }; return _generateCount }
    var resetCount: Int { lock.lock(); defer { lock.unlock() }; return _resetCount }

    func setResponse(_ response: Response) {
        lock.lock(); _response = response; lock.unlock()
    }

    /// Install an async gate run inside `generate` before returning — lets a test
    /// mutate the world (newer keystroke / focus change) while a call is in flight.
    func setGate(_ gate: @escaping @Sendable () async -> Void) {
        lock.lock(); _gate = gate; lock.unlock()
    }

    func generate(_ request: CompletionRequest) async throws -> CompletionResult {
        lock.lock()
        _generateCount += 1
        let response = _response
        let gate = _gate
        lock.unlock()

        if let gate { await gate() }
        try Task.checkCancellation()

        switch response {
        case .text(let text):
            return CompletionResult(text: text, latency: .milliseconds(1))
        case .error(let error):
            throw error
        }
    }

    func reset() async {
        lock.lock(); _resetCount += 1; lock.unlock()
    }
}

// MARK: - FakeOverlay

@MainActor
final class FakeOverlay: OverlayPresenting {
    private(set) var shows: [(text: String, geometry: OverlayGeometry)] = []
    private(set) var repositions: [OverlayGeometry] = []
    private(set) var hides: [String] = []

    var lastShownText: String? { shows.last?.text }
    var showCount: Int { shows.count }
    var repositionCount: Int { repositions.count }

    func show(_ text: String, geometry: OverlayGeometry) {
        shows.append((text, geometry))
    }

    func reposition(geometry: OverlayGeometry) {
        repositions.append(geometry)
    }

    func hide(reason: String) {
        hides.append(reason)
    }
}

// MARK: - FakeInserter

@MainActor
final class FakeInserter: TextInserting {
    var shouldSucceed = true
    private(set) var inserted: [String] = []

    func insert(_ text: String) -> Bool {
        inserted.append(text)
        return shouldSucceed
    }
}

// MARK: - Snapshot builder

@MainActor
enum SnapshotFactory {
    /// A supported, non-secure snapshot with a derived caret and enough text to
    /// pass `AvailabilityEvaluator`.
    static func supported(
        bundleID: String = "com.example.app",
        changeSequence: UInt64 = 1,
        precedingText: String = "hello",
        caret: CaretGeometry? = CaretGeometry(
            rect: CGRect(x: 100, y: 200, width: 2, height: 16),
            quality: .derived,
            observedCharWidth: 8
        )
    ) -> FocusSnapshot {
        FocusSnapshot(
            identity: FocusIdentity(
                bundleID: bundleID,
                pid: 123,
                elementHash: 42,
                changeSequence: changeSequence
            ),
            appName: "Example",
            role: "AXTextArea",
            subrole: nil,
            precedingText: precedingText,
            trailingText: "",
            selection: NSRange(location: 0, length: 0),
            caret: caret,
            isSecure: false,
            capability: .supported
        )
    }
}
