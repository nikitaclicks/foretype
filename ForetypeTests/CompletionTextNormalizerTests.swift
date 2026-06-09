import Testing
import Foundation
@testable import Foretype

/// Tests for the shared, pure `CompletionTextNormalizer` (doc 07).
struct CompletionTextNormalizerTests {

    // MARK: - Helper

    /// Build a minimal `CompletionRequest` directly (NOT via PromptBuilder) so the
    /// normalizer can be exercised in isolation.
    private func request(
        preceding: String = "",
        hint: LengthHint = .medium
    ) -> CompletionRequest {
        CompletionRequest(
            generation: 1,
            precedingText: preceding,
            trailingText: "",
            appName: "TestApp",
            fieldRole: "AXTextField",
            surroundingContext: "",
            lengthHint: hint,
            sampling: SamplingParameters(temperature: 0.2, maxTokens: 48, topP: 0.95),
            prompt: ""
        )
    }

    // MARK: - Echo stripping

    @Test func stripsFullEchoedPrefix() {
        // preceding ends mid-text with no trailing space, so the leading space of
        // the continuation is the natural word separator and must survive — the
        // caret sits right after "brown", and " fox jumps" reinserts as
        // "The quick brown fox jumps". (Mirrors stripsEchoedSuffixOfPreceding.)
        let req = request(preceding: "The quick brown")
        let out = CompletionTextNormalizer.normalize("The quick brown fox jumps", request: req)
        #expect(out == " fox jumps")
    }

    @Test func stripsEchoedSuffixOfPreceding() {
        // Model only echoed the trailing word of the preceding context. The space
        // after the echoed word survives (preceding had no trailing space, so the
        // leading space is treated as intentional continuation spacing).
        let req = request(preceding: "Once upon a time there")
        let out = CompletionTextNormalizer.normalize("there was a dragon", request: req)
        #expect(out == " was a dragon")
    }

    @Test func insertsSeparatorWhenModelStartsFreshWord() {
        // Caret sits at the end of a complete word and the model returned a bare
        // new word with no separator. We must insert the space so it reads
        // "Hello world today", not "Helloworld today".
        let req = request(preceding: "Hello")
        let out = CompletionTextNormalizer.normalize("world today", request: req)
        #expect(out == " world today")
    }

    // MARK: - Quote stripping

    @Test func stripsWrappingDoubleQuotes() {
        let out = CompletionTextNormalizer.normalize("\"completed text\"", request: request())
        #expect(out == "completed text")
    }

    @Test func stripsWrappingSmartQuotes() {
        let out = CompletionTextNormalizer.normalize("\u{201C}hello there\u{201D}", request: request())
        #expect(out == "hello there")
    }

    @Test func doesNotStripUnbalancedQuote() {
        let out = CompletionTextNormalizer.normalize("said \"yes\"", request: request())
        #expect(out == "said \"yes\"")
    }

    // MARK: - Label stripping

    @Test func stripsLeadingLabel() {
        let out = CompletionTextNormalizer.normalize("Continuation: the rest follows", request: request())
        #expect(out == "the rest follows")
    }

    @Test func stripsLeadingDashLabel() {
        let out = CompletionTextNormalizer.normalize("Completion - some words", request: request())
        #expect(out == "some words")
    }

    @Test func keepsRealColonText() {
        // A long phrase before a colon is real text, not a label.
        let out = CompletionTextNormalizer.normalize(
            "this is a much longer sentence: with detail",
            request: request()
        )
        #expect(out == "this is a much longer sentence: with detail")
    }

    // MARK: - Code fences

    @Test func stripsCodeFences() {
        let raw = "```swift\nlet x = 1\n```"
        let out = CompletionTextNormalizer.normalize(raw, request: request())
        #expect(out == "let x = 1")
    }

    @Test func stripsBarePlainCodeFence() {
        let raw = "```\nplain content\n```"
        let out = CompletionTextNormalizer.normalize(raw, request: request())
        #expect(out == "plain content")
    }

    // MARK: - Carriage returns

    @Test func removesCarriageReturns() {
        let out = CompletionTextNormalizer.normalize("line one\r\nline two\r", request: request())
        #expect(!out.contains("\r"))
        #expect(out.contains("line one"))
        #expect(out.contains("line two"))
    }

    // MARK: - Leading-space dedupe

    @Test func dropsLeadingSpaceWhenPrecedingEndsInSpace() {
        let req = request(preceding: "Hello ")
        let out = CompletionTextNormalizer.normalize(" world", request: req)
        #expect(out == "world")
    }

    @Test func stripsRepeatedInProgressWord() {
        // Caret is mid-word ("Hel"); the model reproduced the in-progress word
        // ("Hello") then continued. We strip the repeat so it inserts the rest,
        // reading "Hello there".
        let req = request(preceding: "Hel")
        let out = CompletionTextNormalizer.normalize("Hello there", request: req)
        #expect(out == "lo there")
    }

    @Test func dropsAllLeadingSpaceWhenPrecedingEndsInSpace() {
        // The caret already follows a space, so any leading whitespace the model
        // adds (even multiple) must be dropped — the separator is already there.
        let req = request(preceding: "Hi ")
        let out = CompletionTextNormalizer.normalize("  there", request: req)
        #expect(out == "there")
    }

    // MARK: - Word-boundary reconciliation

    @Test func insertsSeparatorAfterCompleteWord() {
        // The "testingautocomplete" bug: complete word + bare new word → space.
        let req = request(preceding: "testing")
        let out = CompletionTextNormalizer.normalize("autocomplete", request: req)
        #expect(out == " autocomplete")
    }

    @Test func stripsRepeatedPartialWordNoDoubling() {
        // The "double a" bug: caret after a partial word "a"; model repeats it and
        // completes "autocomplete". Strip the echoed "a" so Tab doesn't double it.
        let req = request(preceding: "testing a")
        let out = CompletionTextNormalizer.normalize("autocomplete feature", request: req)
        #expect(out == "utocomplete feature")
    }

    @Test func insertsSeparatorForArticleThenNewWord() {
        // Caret after the article "a"; model starts a different new word with no
        // separator → insert the space ("testing a feature").
        let req = request(preceding: "testing a")
        let out = CompletionTextNormalizer.normalize("feature", request: req)
        #expect(out == " feature")
    }

    @Test func completesSingleWordFromPartial() {
        let req = request(preceding: "bro")
        let out = CompletionTextNormalizer.normalize("brown", request: req)
        #expect(out == "wn")
    }

    @Test func stripsRepeatedWordCaseInsensitively() {
        // Model echoed the in-progress word with different casing; still stripped.
        let req = request(preceding: "hel")
        let out = CompletionTextNormalizer.normalize("Hello world", request: req)
        #expect(out == "lo world")
    }

    // MARK: - Length cap

    @Test func capsShortHintToSevenWords() {
        let req = request(hint: .short)
        let raw = "one two three four five six seven eight nine ten"
        let out = CompletionTextNormalizer.normalize(raw, request: req)
        #expect(out == "one two three four five six seven")
    }

    @Test func capsMediumHintToTwelveWords() {
        let req = request(hint: .medium)
        let raw = "a b c d e f g h i j k l m n o"
        let out = CompletionTextNormalizer.normalize(raw, request: req)
        #expect(out.split(separator: " ").count == 12)
        #expect(out == "a b c d e f g h i j k l")
    }

    @Test func capsLongHintToTwentyWords() {
        let req = request(hint: .long)
        let raw = Array(1...30).map(String.init).joined(separator: " ")
        let out = CompletionTextNormalizer.normalize(raw, request: req)
        #expect(out.split(separator: " ").count == 20)
    }

    @Test func belowCeilingLeavesTextUnchanged() {
        let req = request(hint: .short)
        let out = CompletionTextNormalizer.normalize("just three words", request: req)
        #expect(out == "just three words")
    }

    @Test func capPreservesIntentionalLeadingSpace() {
        // Leading space (caret mid-word) survives the word cap.
        let req = request(preceding: "wor", hint: .short)
        let raw = " ld and many many more words beyond limit"
        let out = CompletionTextNormalizer.normalize(raw, request: req)
        // 7 words kept, leading space preserved.
        #expect(out.hasPrefix(" "))
        #expect(out == " ld and many many more words beyond")
    }

    // MARK: - Empty results

    @Test func returnsEmptyWhenNothingRemains() {
        let out = CompletionTextNormalizer.normalize("   \n  ", request: request())
        #expect(out.isEmpty)
    }

    @Test func returnsEmptyWhenEchoConsumesEverything() {
        let req = request(preceding: "complete sentence")
        let out = CompletionTextNormalizer.normalize("complete sentence", request: req)
        #expect(out.isEmpty)
    }

    @Test func returnsEmptyForEmptyInput() {
        let out = CompletionTextNormalizer.normalize("", request: request())
        #expect(out.isEmpty)
    }

    // MARK: - Combined pipeline

    @Test func handlesLabelQuotesAndEchoTogether() {
        let req = request(preceding: "The answer is ")
        let raw = "Continuation: \"The answer is forty two\""
        let out = CompletionTextNormalizer.normalize(raw, request: req)
        #expect(out == "forty two")
    }

    // MARK: - Determinism

    @Test func isDeterministic() {
        let req = request(preceding: "Some context ", hint: .medium)
        let raw = "Continuation: \"Some context with several extra words appended here\""
        let a = CompletionTextNormalizer.normalize(raw, request: req)
        let b = CompletionTextNormalizer.normalize(raw, request: req)
        #expect(a == b)
    }
}
