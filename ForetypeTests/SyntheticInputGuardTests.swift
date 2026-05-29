import Foundation
import Testing
@testable import Foretype

@MainActor
struct SyntheticInputGuardTests {
    @Test func expectThenExactSuppressionsThenFalse() {
        let guardian = SyntheticInputGuard()
        guardian.expect(count: 3)
        #expect(guardian.shouldSuppress() == true)
        #expect(guardian.shouldSuppress() == true)
        #expect(guardian.shouldSuppress() == true)
        // Count exhausted → no further suppression.
        #expect(guardian.shouldSuppress() == false)
    }

    @Test func noExpectationMeansNoSuppression() {
        let guardian = SyntheticInputGuard()
        #expect(guardian.shouldSuppress() == false)
    }

    @Test func expectationsAccumulate() {
        let guardian = SyntheticInputGuard()
        guardian.expect(count: 2)
        guardian.expect(count: 1)
        #expect(guardian.shouldSuppress() == true)
        #expect(guardian.shouldSuppress() == true)
        #expect(guardian.shouldSuppress() == true)
        #expect(guardian.shouldSuppress() == false)
    }

    @Test func zeroOrNegativeExpectIsNoop() {
        let guardian = SyntheticInputGuard()
        guardian.expect(count: 0)
        guardian.expect(count: -5)
        #expect(guardian.shouldSuppress() == false)
    }

    @Test func expiredExpectationDoesNotSuppress() {
        // Zero-length window: any subsequent call sees the expectation expired.
        let guardian = SyntheticInputGuard(window: 0)
        guardian.expect(count: 2)
        // Date() >= expiry immediately, so the pending count is cleared.
        #expect(guardian.shouldSuppress() == false)
    }
}
