import Foundation

// MARK: - Capability-shaped protocol contracts (doc 11)
//
// The coordinator depends on these, never on concrete services. Nothing the
// coordinator imports knows about AX*, CGEvent, NSPanel, URLSession, or
// UserDefaults. The uniform async-notification style is `AsyncStream`.

/// Permission grant state, owned solely by `PermissionMonitor` (doc 02).
@MainActor
protocol PermissionProviding: AnyObject {
    var accessibilityGranted: Bool { get }
    var inputMonitoringGranted: Bool { get }
    /// Emits whenever either grant flips.
    var changes: AsyncStream<Void> { get }
}

/// Focus snapshots from the polling `FocusWatcher` (doc 03).
@MainActor
protocol FocusProviding: AnyObject {
    /// The latest resolved snapshot, or `nil` when nothing usable is focused.
    /// Used for the freshness re-read on a returning generation (doc 05).
    var current: FocusSnapshot? { get }
    /// Emits a new snapshot only when the resolved state meaningfully changes.
    var snapshots: AsyncStream<FocusSnapshot> { get }
    /// Poke an immediate poll (caret correction after insertion, doc 08).
    func refreshNow()
}

/// The keyboard tap's classified-event sink (doc 04). The closure's return
/// value tells the tap whether to consume the key (true only for an accepted Tab).
@MainActor
protocol InputObserving: AnyObject {
    var onEvent: ((InputEvent) -> Bool)? { get set }
}

/// Synthetic text insertion into the focused field (doc 09).
@MainActor
protocol TextInserting: AnyObject {
    /// Returns success; the coordinator clears the session on failure.
    func insert(_ text: String) -> Bool
}

/// The ghost-text overlay renderer (doc 08). A dumb renderer: it never decides
/// whether to show, only how.
@MainActor
protocol OverlayPresenting: AnyObject {
    func show(_ text: String, geometry: OverlayGeometry)
    func reposition(geometry: OverlayGeometry)
    func hide(reason: String)
}

/// The single source of truth for settings (doc 10).
@MainActor
protocol SettingsProviding: AnyObject {
    var current: Settings { get }
    /// Emits the full settings value whenever any field changes.
    var changes: AsyncStream<Settings> { get }
}
