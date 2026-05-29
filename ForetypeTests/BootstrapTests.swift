import Testing
@testable import Foretype

/// Smoke test confirming the test target hosts in the app and `@testable import`
/// works. Real coverage lives in the per-rule test files (doc 12).
struct BootstrapTests {
    @Test func testTargetIsWired() {
        #expect(Bool(true))
    }
}
