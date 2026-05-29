import CoreGraphics
import Foundation

/// Wraps a single session-level `CGEventTap` listening for key-down and
/// flags-changed events (doc 04). The tap does the minimum synchronously: it
/// consults the `SyntheticInputGuard`, classifies via the pure `InputClassifier`,
/// and forwards a semantic `InputEvent` to the coordinator. The only synchronous
/// decision is whether to *consume* the event — and it consumes only an accepted
/// `Tab`.
///
/// Created only when Input Monitoring is granted. macOS may disable the tap if
/// it is slow or after certain system events; the callback detects
/// `kCGEventTapDisabledByTimeout` / `...DisabledByUserInput` and re-enables it.
@MainActor
final class KeyboardTap: InputObserving {
    var onEvent: ((InputEvent) -> Bool)?

    private let guardian: SyntheticInputGuard
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(guard: SyntheticInputGuard) {
        self.guardian = `guard`
    }

    func start() {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        // Pass an unretained pointer to self; the tap is owned by this object
        // and torn down in stop()/deinit, so the pointer never outlives it.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                KeyboardTap.handle(type: type, event: event, refcon: refcon)
            },
            userInfo: refcon
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.tap = port
        self.runLoopSource = source
    }

    func stop() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    deinit {
        // Run-loop source / mach port teardown is main-actor-isolated state; the
        // owning coordinator calls stop() before releasing. Nothing to do here.
    }

    // MARK: - Callback

    /// The raw C callback trampoline. Runs on the main run loop (the source was
    /// added to it), so touching main-actor state is safe; we assume isolation.
    private static func handle(
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            tap.process(type: type, event: event)
        }
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if macOS disabled the tap; pass the event through unchanged.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Synthetic events from our own insertion: swallow from the
        // classification path (treat as ignored) but pass them through so the
        // host app still receives the typed characters.
        if guardian.shouldSuppress() {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let kind = InputClassifier.classify(keyCode: keyCode, flags: event.flags)

        if kind == .accept {
            let consume = onEvent?(.accept) ?? false
            // Consume the Tab (return nil) only when the coordinator accepted it.
            return consume ? nil : Unmanaged.passUnretained(event)
        }

        // Forward everything else; never consume.
        _ = onEvent?(kind)
        return Unmanaged.passUnretained(event)
    }
}
