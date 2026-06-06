import Testing
import Foundation
@testable import Foretype

struct PromptBuilderTests {

    // MARK: - Helpers

    private func snapshot(
        preceding: String,
        trailing: String = "",
        appName: String = "Notes",
        role: String = "AXTextArea",
        subrole: String? = nil
    ) -> FocusSnapshot {
        FocusSnapshot(
            identity: FocusIdentity(bundleID: "com.apple.Notes", pid: 123, elementHash: 1, changeSequence: 1),
            appName: appName,
            role: role,
            subrole: subrole,
            precedingText: preceding,
            trailingText: trailing,
            selection: NSRange(location: 0, length: 0),
            caret: CaretGeometry(rect: .zero, quality: .exact, observedCharWidth: nil),
            isSecure: false,
            capability: .supported
        )
    }

    private func settings(preset: LengthPreset) -> Settings {
        var s = Settings.default
        s.lengthPreset = preset
        return s
    }

    // MARK: - Determinism

    @Test func identicalInputsYieldIdenticalPrompt() {
        let snap = snapshot(preceding: "The quick brown fox", trailing: "over the lazy dog")
        let set = settings(preset: .medium)

        let a = PromptBuilder.build(snapshot: snap, settings: set, generation: 7)
        let b = PromptBuilder.build(snapshot: snap, settings: set, generation: 7)

        #expect(a == b)
        #expect(a.prompt == b.prompt)
    }

    @Test func generationIsCarriedThrough() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hello"), settings: settings(preset: .short), generation: 42)
        #expect(req.generation == 42)
    }

    // MARK: - Length preset → sampling

    @Test func shortPresetMapsToExpectedSampling() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hi"), settings: settings(preset: .short), generation: 0)
        #expect(req.lengthHint == .short)
        #expect(req.sampling.maxTokens == 24)
        #expect(req.sampling.temperature == 0.2)
        #expect(req.sampling.topP == 0.95)
    }

    @Test func mediumPresetMapsToExpectedSampling() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hi"), settings: settings(preset: .medium), generation: 0)
        #expect(req.lengthHint == .medium)
        #expect(req.sampling.maxTokens == 48)
        #expect(req.sampling.temperature == 0.2)
        #expect(req.sampling.topP == 0.95)
    }

    @Test func longPresetMapsToExpectedSampling() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hi"), settings: settings(preset: .long), generation: 0)
        #expect(req.lengthHint == .long)
        #expect(req.sampling.maxTokens == 80)
        #expect(req.sampling.temperature == 0.2)
        #expect(req.sampling.topP == 0.95)
    }

    // MARK: - Prompt content / framing

    @Test func promptContainsReturnOnlyContinuationInstruction() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hello world"), settings: settings(preset: .medium), generation: 0)
        #expect(req.prompt.contains("Return ONLY the continuation"))
    }

    @Test func promptContainsPrecedingTextTail() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "The meeting is scheduled for"), settings: settings(preset: .short), generation: 0)
        #expect(req.prompt.contains("The meeting is scheduled for"))
    }

    @Test func promptContainsAppName() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "draft", appName: "Mail"), settings: settings(preset: .short), generation: 0)
        #expect(req.prompt.contains("Mail"))
    }

    @Test func promptContainsTrailingText() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "before", trailing: "AFTERTEXT"), settings: settings(preset: .short), generation: 0)
        #expect(req.prompt.contains("AFTERTEXT"))
    }

    @Test func lengthInstructionVariesByPreset() {
        let short = PromptBuilder.build(snapshot: snapshot(preceding: "x"), settings: settings(preset: .short), generation: 0)
        let medium = PromptBuilder.build(snapshot: snapshot(preceding: "x"), settings: settings(preset: .medium), generation: 0)
        let long = PromptBuilder.build(snapshot: snapshot(preceding: "x"), settings: settings(preset: .long), generation: 0)
        #expect(short.prompt.contains("3-7 words"))
        #expect(medium.prompt.contains("7-12 words"))
        #expect(long.prompt.contains("12-20 words"))
    }

    // MARK: - Windowing applied

    @Test func precedingTextIsWindowedToTail() {
        // Build a preceding string well over the 50-word limit.
        let words = (1...200).map { "word\($0)" }.joined(separator: " ")
        let req = PromptBuilder.build(snapshot: snapshot(preceding: words), settings: settings(preset: .medium), generation: 0)

        // The request's precedingText must equal what ContextWindowing produces.
        #expect(req.precedingText == ContextWindowing.windowedPreceding(words))
        // The tail (last word) is retained; the head (first word) is dropped.
        #expect(req.precedingText.contains("word200"))
        #expect(!req.precedingText.contains("word1 "))
        // And the windowed text is embedded in the prompt.
        #expect(req.prompt.contains(req.precedingText))
    }

    @Test func trailingTextIsWindowedToHead() {
        let longTrailing = String(repeating: "z", count: 500)
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hi", trailing: longTrailing), settings: settings(preset: .medium), generation: 0)
        #expect(req.trailingText == ContextWindowing.windowedTrailing(longTrailing))
        #expect(req.trailingText.count <= 200)
        #expect(req.prompt.contains(req.trailingText))
    }

    @Test func shortContextPassesThroughUntouched() {
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "short text", trailing: "tail"), settings: settings(preset: .medium), generation: 0)
        #expect(req.precedingText == "short text")
        #expect(req.trailingText == "tail")
    }

    // MARK: - Surrounding context

    @Test func noSurroundingSectionWhenEmpty() {
        // Default (no surrounding context) must produce a prompt with no
        // background section — guards the byte-identical-when-empty property.
        let req = PromptBuilder.build(snapshot: snapshot(preceding: "hello"), settings: settings(preset: .medium), generation: 0)
        #expect(!req.prompt.contains("Background context"))
        #expect(!req.prompt.contains("Surrounding content:"))
        #expect(req.surroundingContext == "")
    }

    @Test func emptySurroundingProducesIdenticalPromptToNoArgument() {
        let snap = snapshot(preceding: "hello world")
        let set = settings(preset: .medium)
        let withoutArg = PromptBuilder.build(snapshot: snap, settings: set, generation: 1)
        let withEmpty = PromptBuilder.build(snapshot: snap, settings: set, generation: 1, surroundingContext: "")
        #expect(withoutArg.prompt == withEmpty.prompt)
        #expect(withoutArg == withEmpty)
    }

    @Test func surroundingSectionPresentWhenProvided() {
        let req = PromptBuilder.build(
            snapshot: snapshot(preceding: "Let's"),
            settings: settings(preset: .medium),
            generation: 0,
            surroundingContext: "Task: Ship the login fix\nDescription: Users can't sign in"
        )
        #expect(req.prompt.contains("Background context"))
        #expect(req.prompt.contains("Do NOT continue"))
        #expect(req.prompt.contains("Surrounding content:"))
        #expect(req.prompt.contains("Ship the login fix"))
    }

    @Test func surroundingSectionAppearsBeforeCaretContext() {
        let req = PromptBuilder.build(
            snapshot: snapshot(preceding: "PRECEDING_MARKER"),
            settings: settings(preset: .medium),
            generation: 0,
            surroundingContext: "SURROUNDING_MARKER"
        )
        let surroundingRange = req.prompt.range(of: "Surrounding content:")
        let beforeRange = req.prompt.range(of: "Text before caret:")
        #expect(surroundingRange != nil)
        #expect(beforeRange != nil)
        if let s = surroundingRange, let b = beforeRange {
            #expect(s.lowerBound < b.lowerBound)
        }
    }

    @Test func surroundingContextIsWindowedAndCarriedThrough() {
        let oversized = String(repeating: "q", count: SurroundingContextWindowing.totalCharBudget + 1000)
        let req = PromptBuilder.build(
            snapshot: snapshot(preceding: "x"),
            settings: settings(preset: .medium),
            generation: 0,
            surroundingContext: oversized
        )
        #expect(req.surroundingContext == SurroundingContextWindowing.windowed(oversized))
        #expect(req.surroundingContext.count <= SurroundingContextWindowing.totalCharBudget)
        #expect(req.prompt.contains(req.surroundingContext))
    }

    @Test func surroundingContextIsDeterministic() {
        let snap = snapshot(preceding: "The quick brown fox")
        let set = settings(preset: .medium)
        let a = PromptBuilder.build(snapshot: snap, settings: set, generation: 3, surroundingContext: "Background A\nBackground B")
        let b = PromptBuilder.build(snapshot: snap, settings: set, generation: 3, surroundingContext: "Background A\nBackground B")
        #expect(a == b)
        #expect(a.prompt == b.prompt)
    }

    // MARK: - Field role

    @Test func fieldRoleCombinesRoleAndSubrole() {
        let req = PromptBuilder.build(
            snapshot: snapshot(preceding: "x", role: "AXTextField", subrole: "AXSearchField"),
            settings: settings(preset: .short),
            generation: 0
        )
        #expect(req.fieldRole == "AXTextField/AXSearchField")
    }

    @Test func fieldRoleIsRoleAloneWhenNoSubrole() {
        let req = PromptBuilder.build(
            snapshot: snapshot(preceding: "x", role: "AXTextArea", subrole: nil),
            settings: settings(preset: .short),
            generation: 0
        )
        #expect(req.fieldRole == "AXTextArea")
    }
}
