import Testing
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
}
