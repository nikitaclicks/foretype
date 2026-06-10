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

    // MARK: - assemble(scored:) — proximity-biased selection

    /// Build a `ScoredFragment` tersely for tests.
    private static func sf(_ text: String, order: Int, distance: CGFloat, pinned: Bool = false)
        -> SurroundingContextWindowing.ScoredFragment {
        .init(text: text, order: order, distance: distance, pinned: pinned)
    }

    @Test func assembleScoredEmptyStaysEmpty() {
        #expect(SurroundingContextWindowing.assemble(scored: []) == "")
        #expect(SurroundingContextWindowing.assemble(scored: [
            Self.sf("", order: 0, distance: 0),
            Self.sf("   ", order: 1, distance: 1),
        ]) == "")
    }

    @Test func assembleScoredSelectsNearestWhenOverBudget() {
        // Each fragment is at the per-fragment cap; far more than fit in the
        // budget. Distance ASCENDS with document order here, so the nearest
        // (order 0, smallest distance) must survive and the farthest must not —
        // the inverse of the legacy head-retention contract would be the same
        // here, so make the NEAREST be a LATE document fragment below.
        let frags = (0..<100).map { i in
            Self.sf("frag\(i)-" + String(repeating: "x", count: 200), order: i, distance: CGFloat(i))
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        #expect(result.contains("frag0-"))     // nearest (distance 0) kept
        #expect(!result.contains("frag99-"))   // farthest dropped
    }

    @Test func assembleScoredKeepsNearWhenNearIsLateInDocument() {
        // The crux of the fix: the NEAREST fragment is LAST in document order
        // (composer at the bottom). Legacy head-retention would drop it; proximity
        // selection must keep it and evict the distant early fragments.
        let frags = (0..<100).map { i in
            // distance decreases as order increases → last fragment is nearest.
            Self.sf("doc\(i)-" + String(repeating: "y", count: 200), order: i, distance: CGFloat(100 - i))
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        #expect(result.contains("doc99-"))   // nearest (late in document) kept
        #expect(!result.contains("doc0-"))   // most distant (earliest) dropped
    }

    @Test func assembleScoredEmitsInDocumentOrder() {
        // Proximity order (2,0,1) differs from document order (0,1,2). All fit, so
        // all are kept — but output must be in ascending document order.
        let frags = [
            Self.sf("First", order: 0, distance: 50),
            Self.sf("Second", order: 1, distance: 90),
            Self.sf("Third", order: 2, distance: 10),
        ]
        #expect(SurroundingContextWindowing.assemble(scored: frags) == "First\nSecond\nThird")
    }

    @Test func assembleScoredPinnedLeadsAndSurvivesBudget() {
        // A pinned title plus many near fragments that would fill the budget.
        // The title is admitted first, survives, and leads the output.
        var frags = [Self.sf("Task Title", order: 0, distance: 0, pinned: true)]
        frags += (1...100).map { i in
            Self.sf("comment\(i)-" + String(repeating: "z", count: 200), order: i, distance: CGFloat(i))
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.hasPrefix("Task Title\n"))
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
    }

    @Test func assembleScoredFallbackEqualDistancesKeepsHead() {
        // No-composer-frame degeneracy: every distance is 0, so selection
        // collapses to document order and head-retention — identical to the
        // legacy `assemble(fragments:)` path.
        let frags = (1...100).map { i in
            Self.sf("fragment\(i)-" + String(repeating: "x", count: 200), order: i, distance: 0)
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        #expect(result.contains("fragment1-"))
        #expect(!result.contains("fragment100-"))
    }

    @Test func assembleScoredFramelessRanksLast() {
        // A frameless fragment (greatestFiniteMagnitude) must be evicted before a
        // near framed one when only one fits. Two at the per-fragment cap, budget
        // (3000) holds both, so push a third near one to force eviction of the
        // frameless. Simpler: only one slot via maxFragments would over-engineer;
        // instead make both at cap and add enough near ones to exhaust budget.
        var frags = [Self.sf("FRAMELESS-" + String(repeating: "f", count: 200),
                             order: 0, distance: .greatestFiniteMagnitude)]
        frags += (1...20).map { i in
            Self.sf("near\(i)-" + String(repeating: "n", count: 200), order: i, distance: CGFloat(i))
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        #expect(result.contains("near1-"))        // nearest framed kept
        #expect(!result.contains("FRAMELESS-"))   // frameless evicted first
    }

    @Test func assembleScoredJoinedWithinBudgetNoTailTruncation() {
        // Separator accounting must be exact: the last-admitted-by-order fragment
        // must be intact (the final `windowed` must not chop the tail). Build
        // fragments that exactly approach the budget.
        let frags = (0..<50).map { i in
            Self.sf("line\(i)-" + String(repeating: "q", count: 200), order: i, distance: CGFloat(i))
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.count <= SurroundingContextWindowing.totalCharBudget)
        // Every emitted line must be a complete (non-truncated) fragment: it ends
        // with the full 200-char run, never a mid-fragment cut.
        for line in result.split(separator: "\n") {
            #expect(line.hasSuffix(String(repeating: "q", count: 200)))
        }
    }

    @Test func assembleScoredDedupKeepsFirstCasing() {
        let frags = [
            Self.sf("Fix the bug", order: 0, distance: 5),
            Self.sf("fix   the bug", order: 1, distance: 1),
            Self.sf("Ship it", order: 2, distance: 9),
        ]
        // "fix the bug" dedups to the first occurrence's casing regardless of the
        // nearer duplicate; output stays in document order.
        #expect(SurroundingContextWindowing.assemble(scored: frags) == "Fix the bug\nShip it")
    }

    @Test func assembleScoredTieBreaksByDocumentOrder() {
        // Equal distance → earlier document order wins admission. Force a single
        // slot via maxFragments-sized budget pressure by making each at the cap
        // and the budget admit only the earliest few; assert order-2 (later) is
        // dropped before order-0/1 at the same distance.
        let frags = (0..<100).map { i in
            Self.sf("tie\(i)-" + String(repeating: "t", count: 200), order: i, distance: 7)
        }
        let result = SurroundingContextWindowing.assemble(scored: frags)
        #expect(result.contains("tie0-"))
        #expect(!result.contains("tie99-"))
    }

    @Test func assembleScoredIsDeterministic() {
        let frags = [
            Self.sf("Alpha", order: 0, distance: 3),
            Self.sf("Beta", order: 1, distance: 1),
            Self.sf("Gamma", order: 2, distance: 2),
        ]
        #expect(SurroundingContextWindowing.assemble(scored: frags)
                == SurroundingContextWindowing.assemble(scored: frags))
    }

    // MARK: - verticalGap

    @Test func verticalGapZeroWhenVerticallyOverlapping() {
        // Candidate rows intersect the composer's rows.
        let candidate = CGRect(x: 100, y: 520, width: 300, height: 30)  // [520,550] overlaps [500,540]
        #expect(SurroundingContextWindowing.verticalGap(candidate: candidate, composer: Self.composer) == 0)
    }

    @Test func verticalGapAbovePositive() {
        // Candidate fully above: gap = composer.minY - candidate.maxY = 500 - 430 = 70.
        let candidate = CGRect(x: 100, y: 400, width: 300, height: 30)  // maxY 430
        #expect(SurroundingContextWindowing.verticalGap(candidate: candidate, composer: Self.composer) == 70)
    }

    @Test func verticalGapBelowPositive() {
        // Candidate fully below: gap = candidate.minY - composer.maxY = 600 - 540 = 60.
        let candidate = CGRect(x: 100, y: 600, width: 300, height: 30)  // minY 600
        #expect(SurroundingContextWindowing.verticalGap(candidate: candidate, composer: Self.composer) == 60)
    }

    @Test func verticalGapIsDeterministic() {
        let candidate = CGRect(x: 100, y: 300, width: 300, height: 20)
        let a = SurroundingContextWindowing.verticalGap(candidate: candidate, composer: Self.composer)
        let b = SurroundingContextWindowing.verticalGap(candidate: candidate, composer: Self.composer)
        #expect(a == b)
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
