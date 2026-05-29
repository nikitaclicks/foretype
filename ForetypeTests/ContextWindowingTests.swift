import Testing
@testable import Foretype

/// Tests for ContextWindowing (doc 06): tail retention, word + char caps,
/// empty input, short-text passthrough, and the trailing head window.
struct ContextWindowingTests {

    // MARK: - Preceding: empty and short passthrough

    @Test func precedingEmptyStaysEmpty() {
        #expect(ContextWindowing.windowedPreceding("") == "")
    }

    @Test func precedingShortTextUnchanged() {
        let text = "The quick brown fox jumps over the lazy dog."
        #expect(ContextWindowing.windowedPreceding(text) == text)
    }

    @Test func precedingTextAtCharLimitUnchanged() {
        let text = String(repeating: "a", count: 1000)
        #expect(ContextWindowing.windowedPreceding(text) == text)
    }

    // MARK: - Preceding: character cap, tail retention

    @Test func precedingCharCapKeepsTail() {
        // A single long run of non-space chars: only the char cap applies.
        let text = String(repeating: "x", count: 1500)
        let result = ContextWindowing.windowedPreceding(text)
        #expect(result.count == 1000)
        // The tail must be retained: the result is the LAST 1000 chars, so it
        // is a suffix of the original.
        #expect(text.hasSuffix(result))
    }

    @Test func precedingRetainsCaretAdjacentTail() {
        // Distinct head and tail markers; the tail (near the caret) must survive.
        let head = String(repeating: "H", count: 1200)
        let tailMarker = "CARET_NEIGHBOR"
        let text = head + tailMarker
        let result = ContextWindowing.windowedPreceding(text)
        #expect(result.hasSuffix(tailMarker))
        #expect(result.count == 1000)
    }

    // MARK: - Preceding: word cap, tail retention

    @Test func precedingWordCapKeepsLastWords() {
        // 60 short words separated by single spaces -> word cap (50) bites first.
        let words = (1...60).map { "w\($0)" }
        let text = words.joined(separator: " ")
        let result = ContextWindowing.windowedPreceding(text)
        let resultWords = result.split(separator: " ")
        #expect(resultWords.count == 50)
        // Must keep the LAST 50 words: w11 ... w60.
        #expect(resultWords.first == "w11")
        #expect(resultWords.last == "w60")
        #expect(result.hasSuffix("w60"))
    }

    @Test func precedingFiftyWordsUnchanged() {
        let words = (1...50).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let result = ContextWindowing.windowedPreceding(text)
        #expect(result == text)
    }

    @Test func precedingBothCapsAppliedKeepsTail() {
        // Many long words: both word and char caps may bite; result must still
        // be a suffix of the input and within both limits.
        let words = (1...80).map { _ in String(repeating: "z", count: 40) }
        let text = words.joined(separator: " ")
        let result = ContextWindowing.windowedPreceding(text)
        #expect(result.count <= 1000)
        #expect(text.hasSuffix(result))
    }

    // MARK: - Determinism

    @Test func precedingIsDeterministic() {
        let text = String(repeating: "lorem ipsum ", count: 200)
        #expect(ContextWindowing.windowedPreceding(text) == ContextWindowing.windowedPreceding(text))
    }

    // MARK: - Trailing

    @Test func trailingEmptyStaysEmpty() {
        #expect(ContextWindowing.windowedTrailing("") == "")
    }

    @Test func trailingShortTextUnchanged() {
        let text = "and then they lived happily ever after."
        #expect(ContextWindowing.windowedTrailing(text) == text)
    }

    @Test func trailingAtLimitUnchanged() {
        let text = String(repeating: "b", count: 200)
        #expect(ContextWindowing.windowedTrailing(text) == text)
    }

    @Test func trailingCapKeepsHead() {
        let text = String(repeating: "c", count: 500)
        let result = ContextWindowing.windowedTrailing(text)
        #expect(result.count == 200)
        // The HEAD must be retained: result is a prefix of the original.
        #expect(text.hasPrefix(result))
    }

    @Test func trailingRetainsCaretAdjacentHead() {
        let headMarker = "AFTER_CARET"
        let text = headMarker + String(repeating: "t", count: 500)
        let result = ContextWindowing.windowedTrailing(text)
        #expect(result.hasPrefix(headMarker))
        #expect(result.count == 200)
    }

    @Test func trailingIsDeterministic() {
        let text = String(repeating: "tail ", count: 100)
        #expect(ContextWindowing.windowedTrailing(text) == ContextWindowing.windowedTrailing(text))
    }
}
