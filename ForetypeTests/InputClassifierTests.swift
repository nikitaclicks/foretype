import CoreGraphics
import Testing
@testable import Foretype

struct InputClassifierTests {
    // Keycodes used in assertions.
    private let tab: Int64 = 48
    private let escape: Int64 = 53
    private let leftArrow: Int64 = 123
    private let c: Int64 = 8
    private let v: Int64 = 9
    private let z: Int64 = 6

    @Test func bareTabIsAccept() {
        #expect(InputClassifier.classify(keyCode: tab, flags: []) == .accept)
    }

    @Test func commandTabIsIgnored() {
        #expect(InputClassifier.classify(keyCode: tab, flags: .maskCommand) == .ignored)
    }

    @Test func letterIsTextMutation() {
        // 'a' keycode 0, no modifiers.
        #expect(InputClassifier.classify(keyCode: 0, flags: []) == .textMutation)
    }

    @Test func commandVIsShortcutMutation() {
        #expect(InputClassifier.classify(keyCode: v, flags: .maskCommand) == .shortcutMutation)
    }

    @Test func commandZIsShortcutMutation() {
        #expect(InputClassifier.classify(keyCode: z, flags: .maskCommand) == .shortcutMutation)
        #expect(
            InputClassifier.classify(keyCode: z, flags: [.maskCommand, .maskShift]) == .shortcutMutation
        )
    }

    @Test func arrowIsNavigation() {
        #expect(InputClassifier.classify(keyCode: leftArrow, flags: []) == .navigation)
    }

    @Test func escapeIsDismiss() {
        #expect(InputClassifier.classify(keyCode: escape, flags: []) == .dismiss)
    }

    @Test func commandCIsDismiss() {
        #expect(InputClassifier.classify(keyCode: c, flags: .maskCommand) == .dismiss)
    }

    @Test func pureModifierIsIgnored() {
        // Command key itself (keycode 55) with the command flag set is a pure
        // modifier press → ignored.
        #expect(InputClassifier.classify(keyCode: 55, flags: .maskCommand) == .ignored)
    }
}
