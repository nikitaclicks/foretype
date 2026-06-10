import Testing
import Foundation
@testable import Foretype

struct AvailabilityEvaluatorTests {

    /// Builds a fully-valid snapshot (would yield `.mayGenerate`) so each test
    /// can perturb exactly one field to exercise one branch.
    private func makeSnapshot(
        bundleID: String = "com.example.editor",
        precedingText: String = "hello world",
        caret: CaretGeometry? = CaretGeometry(
            rect: CGRect(x: 10, y: 20, width: 1, height: 16),
            quality: .derived,
            observedCharWidth: 7,
            font: nil,
            color: nil
        ),
        fieldRect: CGRect? = CGRect(x: 0, y: 0, width: 300, height: 24),
        isSecure: Bool = false,
        capability: FocusCapability = .supported
    ) -> FocusSnapshot {
        FocusSnapshot(
            identity: FocusIdentity(bundleID: bundleID, pid: 1234, elementHash: 99, changeSequence: 1),
            appName: "Editor",
            role: "AXTextArea",
            subrole: nil,
            precedingText: precedingText,
            trailingText: "",
            selection: NSRange(location: 11, length: 0),
            caret: caret,
            fieldRect: fieldRect,
            isSecure: isSecure,
            capability: capability
        )
    }

    private func evaluate(
        snapshot: FocusSnapshot?,
        settings: Settings = .default,
        accessibility: Bool = true,
        inputMonitoring: Bool = true,
        backendAvailable: Bool = true
    ) -> AvailabilityDecision {
        AvailabilityEvaluator.evaluate(
            snapshot: snapshot,
            settings: settings,
            accessibilityGranted: accessibility,
            inputMonitoringGranted: inputMonitoring,
            backendAvailable: backendAvailable
        )
    }

    @Test func permissionMissing_whenAccessibilityNotGranted() {
        #expect(evaluate(snapshot: makeSnapshot(), accessibility: false) == .disabled(.permissionMissing))
    }

    @Test func permissionMissing_whenInputMonitoringNotGranted() {
        #expect(evaluate(snapshot: makeSnapshot(), inputMonitoring: false) == .disabled(.permissionMissing))
    }

    @Test func permissionMissing_takesPriorityOverEverythingElse() {
        // Even with global off + nil snapshot, missing perms wins (order).
        var settings = Settings.default
        settings.isEnabled = false
        #expect(evaluate(snapshot: nil, settings: settings, accessibility: false, backendAvailable: false) == .disabled(.permissionMissing))
    }

    @Test func globallyOff_whenDisabled() {
        var settings = Settings.default
        settings.isEnabled = false
        #expect(evaluate(snapshot: makeSnapshot(), settings: settings) == .disabled(.globallyOff))
    }

    @Test func backendUnavailable_whenBackendDown() {
        #expect(evaluate(snapshot: makeSnapshot(), backendAvailable: false) == .disabled(.backendUnavailable))
    }

    @Test func fieldUnsupported_whenNilSnapshot() {
        #expect(evaluate(snapshot: nil) == .disabled(.fieldUnsupported))
    }

    @Test func fieldSecure_whenSnapshotIsSecure() {
        #expect(evaluate(snapshot: makeSnapshot(isSecure: true)) == .disabled(.fieldSecure))
    }

    @Test func fieldSecure_whenCapabilityBlocked() {
        #expect(evaluate(snapshot: makeSnapshot(capability: .blocked(reason: "secure"))) == .disabled(.fieldSecure))
    }

    @Test func appDisabledByRule_whenBlockRuleMatches() {
        var settings = Settings.default
        settings.appRules = [AppRule(bundleID: "com.example.editor", mode: .block)]
        #expect(evaluate(snapshot: makeSnapshot(bundleID: "com.example.editor"), settings: settings) == .disabled(.appDisabledByRule))
    }

    @Test func fieldUnsupported_whenCapabilityUnsupported() {
        #expect(evaluate(snapshot: makeSnapshot(capability: .unsupported(reason: "no text"))) == .disabled(.fieldUnsupported))
    }

    @Test func fieldUnsupported_whenCaretNil() {
        #expect(evaluate(snapshot: makeSnapshot(caret: nil)) == .disabled(.fieldUnsupported))
    }

    @Test func fieldUnsupported_whenCaretEstimated() {
        let caret = CaretGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 16), quality: .estimated, observedCharWidth: nil, font: nil, color: nil)
        #expect(evaluate(snapshot: makeSnapshot(caret: caret)) == .disabled(.fieldUnsupported))
    }

    @Test func fieldUnsupported_whenFewerThanTwoNonWhitespaceChars() {
        // One non-whitespace char surrounded by whitespace.
        #expect(evaluate(snapshot: makeSnapshot(precedingText: "  a  ")) == .disabled(.fieldUnsupported))
    }

    @Test func fieldUnsupported_whenOnlyWhitespace() {
        #expect(evaluate(snapshot: makeSnapshot(precedingText: "    ")) == .disabled(.fieldUnsupported))
    }

    @Test func mayGenerate_happyPath() {
        #expect(evaluate(snapshot: makeSnapshot()) == .mayGenerate)
    }

    @Test func mayGenerate_withExactlyTwoNonWhitespaceChars() {
        #expect(evaluate(snapshot: makeSnapshot(precedingText: " a b ")) == .mayGenerate)
    }

    @Test func mayGenerate_withExactCaretQuality() {
        let caret = CaretGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 16), quality: .exact, observedCharWidth: 7, font: nil, color: nil)
        #expect(evaluate(snapshot: makeSnapshot(caret: caret)) == .mayGenerate)
    }
}
