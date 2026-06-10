import Testing
import CoreGraphics
import ApplicationServices
@testable import Foretype

/// Tests for SurroundingContextWindowing (doc 06): fragment assembly with
/// dedup + per-fragment cap + total budget (head retention), idempotent
/// windowing, and overlap removal against the in-progress preceding text.
struct SurroundingContextWindowingTests {

    // MARK: - assemble

    @Test func assembleEmptyStaysEmpty() {
        #expect(SurroundingContextWindowing.assemble(fragments: []) == "")
        #expect(SurroundingContextWindowing.assemble(fragments: ["", "  ", "\n"]) == "")
    }

    @Test func assembleJoinsFragmentsInOrder() {
        let result = SurroundingContextWindowing.assemble(fragments: ["Title", "Description", "A comment"])
        #expect(result == "Title\nDescription\nA comment")
    }

    @Test func assembleTrimsFragmentsAndDropsEmpties() {
        let result = SurroundingContextWindowing.assemble(fragments: ["  Title  ", "", "   ", " Body "])
        #expect(result == "Title\nBody")
    }

    @Test func assembleDeduplicatesNormalizedFragments() {
        // Same text with different casing/spacing collapses to one entry; the
        // first occurrence's original casing is retained.
        let result = SurroundingContextWindowing.assemble(fragments: ["Fix the bug", "fix   the bug", "FIX THE BUG", "Ship it"])
        #expect(result == "Fix the bug\nShip it")
    }

    @Test func assembleCapsEachFragmentToHead() {
        let huge = String(repeating: "z", count: 1000)
        let result = SurroundingContextWindowing.assemble(fragments: [huge])
        #expect(result.count == SurroundingContextWindowing.perFragmentCharCap)
        #expect(huge.hasPrefix(result))
    }

    @Test func assembleCapsTotalToBudgetKeepingHead() {
        // Many distinct fragments, each at the per-fragment cap, well over budget.
        let fragments = (1...100).map { "fragment\($0)-" + String(repeating: "x", count: 200) }
        let result = SurroundingContextWindowing.assemble(fragments: fragments)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        // Head retained: the first fragment survives, a late one does not.
        #expect(result.contains("fragment1-"))
        #expect(!result.contains("fragment100-"))
    }

    @Test func assembleHonorsMaxFragments() {
        let fragments = (1...500).map { "f\($0)" }
        let result = SurroundingContextWindowing.assemble(fragments: fragments)
        let lines = result.split(separator: "\n")
        #expect(lines.count <= SurroundingContextWindowing.maxFragments)
        #expect(lines.first == "f1")
    }

    @Test func assembleIsDeterministic() {
        let fragments = ["Alpha", "Beta", "Alpha", "Gamma"]
        #expect(SurroundingContextWindowing.assemble(fragments: fragments)
                == SurroundingContextWindowing.assemble(fragments: fragments))
    }

    // MARK: - windowed (idempotent cap)

    @Test func windowedEmptyStaysEmpty() {
        #expect(SurroundingContextWindowing.windowed("") == "")
        #expect(SurroundingContextWindowing.windowed("   \n  ") == "")
    }

    @Test func windowedUnderBudgetPassesThrough() {
        let text = "Task title\nSome description"
        #expect(SurroundingContextWindowing.windowed(text) == text)
    }

    @Test func windowedOverBudgetCapsToHead() {
        let text = String(repeating: "a", count: SurroundingContextWindowing.totalCharBudget + 500)
        let result = SurroundingContextWindowing.windowed(text)
        #expect(result.count == SurroundingContextWindowing.totalCharBudget)
        #expect(text.hasPrefix(result))
    }

    @Test func windowedIsIdempotent() {
        let text = (1...100).map { "line\($0) " + String(repeating: "y", count: 100) }.joined(separator: "\n")
        let once = SurroundingContextWindowing.windowed(text)
        let twice = SurroundingContextWindowing.windowed(once)
        #expect(once == twice)
    }

    // MARK: - removingOverlap

    @Test func removingOverlapDropsFragmentEqualToPreceding() {
        let context = "Task title\nWe should fix the login bug\nAnother comment"
        let preceding = "We should fix the login bug"
        let result = SurroundingContextWindowing.removingOverlap(context, with: preceding)
        #expect(!result.contains("We should fix the login bug"))
        #expect(result.contains("Task title"))
        #expect(result.contains("Another comment"))
    }

    @Test func removingOverlapDropsFragmentContainedInPreceding() {
        // The preceding tail contains the fragment verbatim.
        let context = "the login bug\nUnrelated note"
        let preceding = "We really should fix the login bug today"
        let result = SurroundingContextWindowing.removingOverlap(context, with: preceding)
        #expect(!result.contains("the login bug"))
        #expect(result.contains("Unrelated note"))
    }

    @Test func removingOverlapKeepsUnrelatedFragments() {
        let context = "Task title\nDescription text\nEarlier comment"
        let preceding = "I am typing something completely different here"
        let result = SurroundingContextWindowing.removingOverlap(context, with: preceding)
        #expect(result == context)
    }

    @Test func removingOverlapEmptyPrecedingIsNoOp() {
        let context = "Task title\nDescription"
        #expect(SurroundingContextWindowing.removingOverlap(context, with: "") == context)
        #expect(SurroundingContextWindowing.removingOverlap(context, with: "   ") == context)
    }

    @Test func removingOverlapShortPrecedingDoesNotOverDrop() {
        // A 2-char preceding fragment must not nuke unrelated lines that happen
        // to contain those letters.
        let context = "Tahiti vacation plan\nProject roadmap"
        let preceding = "Ta"
        let result = SurroundingContextWindowing.removingOverlap(context, with: preceding)
        #expect(result == context)
    }

    // MARK: - spatial proximity

    // A composer column at x:[100,400], y:[500,540] (AX top-left, y-down). With
    // aboveFactor 8 and belowFactor 2 on height 40, the vertical band is
    // [500 - 320, 540 + 80] = [180, 620].
    private static let composer = CGRect(x: 100, y: 500, width: 300, height: 40)

    @Test func horizontalOverlapIdenticalIsFull() {
        #expect(SurroundingContextWindowing.horizontalOverlapFraction(Self.composer, Self.composer) == 1.0)
    }

    @Test func horizontalOverlapDisjointIsZero() {
        let candidate = CGRect(x: 500, y: 500, width: 200, height: 40)  // entirely right of composer
        #expect(SurroundingContextWindowing.horizontalOverlapFraction(candidate, Self.composer) == 0)
    }

    @Test func horizontalOverlapHalf() {
        // candidate x:[250,550] width 300; overlap with composer x:[100,400] is
        // [250,400] = 150 → 150/300 = 0.5.
        let candidate = CGRect(x: 250, y: 400, width: 300, height: 30)
        #expect(SurroundingContextWindowing.horizontalOverlapFraction(candidate, Self.composer) == 0.5)
    }

    @Test func horizontalOverlapZeroWidthCandidateIsZero() {
        let candidate = CGRect(x: 200, y: 400, width: 0, height: 30)
        #expect(SurroundingContextWindowing.horizontalOverlapFraction(candidate, Self.composer) == 0)
    }

    @Test func spatialDirectlyAboveSameColumnIsRelated() {
        // Same column, just above the composer (smaller y) — the thread/message.
        let candidate = CGRect(x: 100, y: 400, width: 300, height: 30)
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer))
    }

    @Test func spatialDifferentColumnIsNotRelated() {
        // The main view beside a narrow side-chat: same vertical band, different
        // column → dropped by horizontal overlap. This is the side-chat fix.
        let candidate = CGRect(x: 450, y: 450, width: 300, height: 30)
        #expect(!SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer))
    }

    @Test func spatialFarAboveBeyondWindowIsNotRelated() {
        // Same column but far above the band top (180): a distant feed item.
        let candidate = CGRect(x: 100, y: 100, width: 300, height: 30)  // maxY 130 < 180
        #expect(!SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer))
    }

    @Test func spatialFarBelowBeyondWindowIsNotRelated() {
        // Same column but below the band bottom (620): a distant feed item. The
        // Twitter fix — unrelated timeline content under an inline reply box.
        let candidate = CGRect(x: 100, y: 700, width: 300, height: 30)  // minY 700 > 620
        #expect(!SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer))
    }

    @Test func spatialJustBelowWithinWindowIsRelated() {
        let candidate = CGRect(x: 100, y: 560, width: 300, height: 30)  // within [180,620]
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer))
    }

    @Test func spatialZeroAreaCandidateIsRelated() {
        // No usable frame → cannot localize → keep (don't over-filter).
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: .zero, composer: Self.composer))
        let empty = CGRect(x: 100, y: 400, width: 0, height: 0)
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: empty, composer: Self.composer))
    }

    @Test func spatialEmptyComposerDisablesFilter() {
        let candidate = CGRect(x: 9000, y: 9000, width: 300, height: 30)
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: .zero))
    }

    @Test func spatialDirectionIsYDownAboveMeansSmallerY() {
        // Pin the AX y-down convention: a node ABOVE (smaller y) within reach is
        // related; the same-distance node BELOW beyond the (smaller) below-window
        // is not. composer y:[500,540]; above reach 320, below reach 80.
        let above = CGRect(x: 100, y: 300, width: 300, height: 20)  // 200px above top → within 320
        let below = CGRect(x: 100, y: 660, width: 300, height: 20)  // 120px below bottom → beyond 80
        #expect(SurroundingContextWindowing.isSpatiallyRelated(candidate: above, composer: Self.composer))
        #expect(!SurroundingContextWindowing.isSpatiallyRelated(candidate: below, composer: Self.composer))
    }

    @Test func spatialIsDeterministic() {
        let candidate = CGRect(x: 120, y: 420, width: 280, height: 30)
        let a = SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer)
        let b = SurroundingContextWindowing.isSpatiallyRelated(candidate: candidate, composer: Self.composer)
        #expect(a == b)
    }

    // MARK: - context eligibility gate

    @MainActor
    @Test func contextEligibleForTextArea() {
        #expect(CompletionCoordinator.isContextEligible(role: kAXTextAreaRole as String, subrole: nil))
    }

    @MainActor
    @Test func contextEligibleForTextFieldAndComboBox() {
        // Single-line web composers (Twitter reply, ClickUp side-chat) qualify.
        #expect(CompletionCoordinator.isContextEligible(role: kAXTextFieldRole as String, subrole: nil))
        #expect(CompletionCoordinator.isContextEligible(role: "AXComboBox", subrole: nil))
    }

    @MainActor
    @Test func contextNotEligibleForSearchField() {
        // A search box would only pull unrelated panel noise.
        #expect(!CompletionCoordinator.isContextEligible(
            role: kAXTextFieldRole as String,
            subrole: kAXSearchFieldSubrole as String
        ))
    }

    @MainActor
    @Test func contextNotEligibleForOtherRoles() {
        #expect(!CompletionCoordinator.isContextEligible(role: "AXButton", subrole: nil))
        #expect(!CompletionCoordinator.isContextEligible(role: "AXStaticText", subrole: nil))
    }
}
