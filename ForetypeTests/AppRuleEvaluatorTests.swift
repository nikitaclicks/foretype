import Testing
@testable import Foretype

struct AppRuleEvaluatorTests {
    private func settings(appRules: [AppRule]) -> Settings {
        var s = Settings.default
        s.appRules = appRules
        return s
    }

    @Test func enabledByDefaultWithNoRules() {
        let s = settings(appRules: [])
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.example.app", settings: s) == true)
    }

    @Test func blockedWhenBlockRuleMatches() {
        let s = settings(appRules: [AppRule(bundleID: "com.example.app", mode: .block)])
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.example.app", settings: s) == false)
    }

    @Test func unrelatedBlockRuleDoesNotBlock() {
        let s = settings(appRules: [AppRule(bundleID: "com.other.app", mode: .block)])
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.example.app", settings: s) == true)
    }

    @Test func allowModeRuleDoesNotBlockUnderBlocklist() {
        // An .allow rule for a different app must not block, and an .allow rule
        // for the same app must not (somehow) enable-only-this — under a
        // blocklist policy, allow rules are inert.
        let s = settings(appRules: [
            AppRule(bundleID: "com.allowed.app", mode: .allow)
        ])
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.example.app", settings: s) == true)
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.allowed.app", settings: s) == true)
    }

    @Test func blockTakesEffectAlongsideOtherRules() {
        let s = settings(appRules: [
            AppRule(bundleID: "com.allowed.app", mode: .allow),
            AppRule(bundleID: "com.blocked.app", mode: .block),
        ])
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.blocked.app", settings: s) == false)
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.allowed.app", settings: s) == true)
        #expect(AppRuleEvaluator.isEnabled(bundleID: "com.unlisted.app", settings: s) == true)
    }
}
