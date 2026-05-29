import Foundation

/// Pure evaluation of per-app enable/disable rules (doc 10).
///
/// Policy is a **blocklist**: Foretype is enabled in every app *except* those
/// that have an `AppRule` with `mode == .block` matching their bundle id. An
/// `.allow`-mode rule has no effect under this policy (it would only matter
/// under an allowlist policy, which we do not use).
///
/// This does **not** consult `settings.isEnabled` — the global toggle is a
/// separate concern handled by `AvailabilityEvaluator` (doc 05).
enum AppRuleEvaluator {
    /// Returns true unless an `.block` rule matches `bundleID`.
    static func isEnabled(bundleID: String, settings: Settings) -> Bool {
        !settings.appRules.contains { $0.mode == .block && $0.bundleID == bundleID }
    }
}
