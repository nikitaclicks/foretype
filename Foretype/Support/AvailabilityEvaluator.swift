import Foundation

/// The outcome of a precondition check: either generation may proceed, or it is
/// disabled for a specific reason (surfaced in the menu bar). See doc 05,
/// "Request preconditions".
enum AvailabilityDecision: Equatable {
    case mayGenerate
    case disabled(DisabledReason)
}

/// Pure folding of all generation preconditions into a single decision. The
/// coordinator asks this before scheduling work and reacts to the result; it
/// holds no logic of its own. No I/O, no AX, no clock — every input is passed in.
/// See doc 05.
enum AvailabilityEvaluator {
    /// Evaluate preconditions IN ORDER, returning the first failing reason or
    /// `.mayGenerate` if all hold. The ordering is significant: earlier reasons
    /// are more fundamental (permissions before global toggle before backend,
    /// then field-level checks).
    static func evaluate(
        snapshot: FocusSnapshot?,
        settings: Settings,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool,
        backendAvailable: Bool
    ) -> AvailabilityDecision {
        // 1. Both permissions must be granted.
        guard accessibilityGranted, inputMonitoringGranted else {
            return .disabled(.permissionMissing)
        }

        // 2. Global toggle must be on.
        guard settings.isEnabled else {
            return .disabled(.globallyOff)
        }

        // 3. The selected backend must be reachable/usable.
        guard backendAvailable else {
            return .disabled(.backendUnavailable)
        }

        // 4. There must be a usable focused field.
        guard let snapshot else {
            return .disabled(.fieldUnsupported)
        }

        // 5. Secure fields and explicitly blocked capabilities never complete.
        if snapshot.isSecure {
            return .disabled(.fieldSecure)
        }
        if case .blocked = snapshot.capability {
            return .disabled(.fieldSecure)
        }

        // 6. The focused app must not be disabled by an app rule.
        guard AppRuleEvaluator.isEnabled(bundleID: snapshot.identity.bundleID, settings: settings) else {
            return .disabled(.appDisabledByRule)
        }

        // 7. The field must be supported (not .unsupported / not anything else).
        guard snapshot.capability == .supported else {
            return .disabled(.fieldUnsupported)
        }

        // 8. We anchor ghost text to the caret, so we need a caret rect of at
        //    least `derived` quality to place it.
        guard let caret = snapshot.caret, caret.quality != .estimated else {
            return .disabled(.fieldUnsupported)
        }

        // 9. A single character is too noisy to complete — require ≥2 non-whitespace.
        let nonWhitespaceCount = snapshot.precedingText.filter { !$0.isWhitespace }.count
        guard nonWhitespaceCount >= 2 else {
            return .disabled(.fieldUnsupported)
        }

        return .mayGenerate
    }
}
