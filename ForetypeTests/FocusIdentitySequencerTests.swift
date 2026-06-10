import Testing
import Foundation
@testable import Foretype

struct FocusIdentitySequencerTests {
    typealias Seq = FocusIdentitySequencer

    private let sigA = "AXTextArea||100|200|600"
    private let sigB = "AXTextField||100|260|300"

    @Test func firstFocusIsAlwaysAChange() {
        let r = Seq.resolve(hash: 1, pid: 42, signature: sigA, prior: .none)
        #expect(r.identityChanged)
        #expect(r.stableHash == 1)
    }

    @Test func sameHashSameField() {
        let prior = Seq.Prior(hash: 7, pid: 42, signature: sigA)
        let r = Seq.resolve(hash: 7, pid: 42, signature: sigA, prior: prior)
        #expect(!r.identityChanged)
        #expect(r.stableHash == 7)
    }

    @Test func differentPidIsAlwaysAChange() {
        let prior = Seq.Prior(hash: 7, pid: 42, signature: sigA)
        // Same hash value but a different process is unambiguously a new field.
        let r = Seq.resolve(hash: 7, pid: 99, signature: sigA, prior: prior)
        #expect(r.identityChanged)
        #expect(r.stableHash == 7)
    }

    // The core regression: a Chromium contenteditable hands out a new hash every
    // poll while the field's structure is unchanged. Identity must hold steady.
    @Test func churningHashWithStableSignatureKeepsPriorIdentity() {
        let prior = Seq.Prior(hash: 7, pid: 42, signature: sigA)
        let r = Seq.resolve(hash: 999, pid: 42, signature: sigA, prior: prior)
        #expect(!r.identityChanged)
        #expect(r.stableHash == 7)   // keeps the prior hash, not the churned one
    }

    @Test func newHashWithDifferentSignatureIsAChange() {
        let prior = Seq.Prior(hash: 7, pid: 42, signature: sigA)
        let r = Seq.resolve(hash: 8, pid: 42, signature: sigB, prior: prior)
        #expect(r.identityChanged)
        #expect(r.stableHash == 8)
    }

    @Test func newHashWithNoSignatureIsAChange() {
        // Without a frame to anchor stability, a new hash must be treated as new.
        let prior = Seq.Prior(hash: 7, pid: 42, signature: nil)
        let r = Seq.resolve(hash: 8, pid: 42, signature: nil, prior: prior)
        #expect(r.identityChanged)
        #expect(r.stableHash == 8)
    }

    // Browser tab switch: the composer in two tabs of one window shares
    // role|subrole|x|y|w, so only the per-tab AXURL that FocusWatcher appends to
    // the signature distinguishes them. A different URL (churned hash) must read
    // as a genuine field change so the coordinator clears Tab A's session/context.
    @Test func tabSwitchChangesIdentity() {
        let tabA = "AXTextArea||100|200|600|https://app.example.com/t/AAA"
        let tabB = "AXTextArea||100|200|600|https://app.example.com/t/BBB"
        let prior = Seq.Prior(hash: 7, pid: 42, signature: tabA)
        let r = Seq.resolve(hash: 999, pid: 42, signature: tabB, prior: prior)
        #expect(r.identityChanged)
        #expect(r.stableHash == 999)
    }

    // Within one tab, the URL is stable while typing, so the keystroke-driven hash
    // churn must still collapse to the prior identity (no per-keystroke teardown).
    @Test func sameTabChurnStillCollapses() {
        let tab = "AXTextArea||100|200|600|https://app.example.com/t/AAA"
        let prior = Seq.Prior(hash: 7, pid: 42, signature: tab)
        let r = Seq.resolve(hash: 999, pid: 42, signature: tab, prior: prior)
        #expect(!r.identityChanged)
        #expect(r.stableHash == 7)
    }

    // Repeated churn converges: every poll keeps returning the same stable hash,
    // so the embedded identity never drifts.
    @Test func repeatedChurnStaysStable() {
        var prior = Seq.Prior(hash: 7, pid: 42, signature: sigA)
        for churn in [101, 102, 103, 104] {
            let r = Seq.resolve(hash: churn, pid: 42, signature: sigA, prior: prior)
            #expect(!r.identityChanged)
            #expect(r.stableHash == 7)
            // Caller does NOT update lastElementHash when unchanged, so prior holds.
            prior = Seq.Prior(hash: prior.hash, pid: 42, signature: sigA)
        }
    }
}
