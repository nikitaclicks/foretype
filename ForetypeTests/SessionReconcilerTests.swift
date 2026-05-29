import Testing
@testable import Foretype

struct SessionReconcilerTests {

    // MARK: - nextChunk

    @Test func nextChunkIncludesTrailingSpace() {
        let session = ActiveSession(fullText: "world foo")
        #expect(SessionReconciler.nextChunk(session) == "world ")
    }

    @Test func nextChunkStopsAtPunctuationBoundary() {
        // Word followed by a comma and a space — the trailing boundary run
        // (",  ") is swept up with the word.
        let session = ActiveSession(fullText: "hello, world")
        #expect(SessionReconciler.nextChunk(session) == "hello, ")
    }

    @Test func nextChunkPunctuationOnlyBoundaryRun() {
        // Multiple punctuation/spaces following a word are all consumed.
        let session = ActiveSession(fullText: "end... more")
        #expect(SessionReconciler.nextChunk(session) == "end... ")
    }

    @Test func nextChunkSingleTrailingWordNoBoundary() {
        // A single word with no trailing boundary → the whole remainder.
        let session = ActiveSession(fullText: "completion")
        #expect(SessionReconciler.nextChunk(session) == "completion")
    }

    @Test func nextChunkEmptyRemainder() {
        let session = ActiveSession(fullText: "done", consumedCount: 4)
        #expect(session.remainder.isEmpty)
        #expect(SessionReconciler.nextChunk(session) == "")
    }

    @Test func nextChunkEmptyFullText() {
        let session = ActiveSession(fullText: "")
        #expect(SessionReconciler.nextChunk(session) == "")
    }

    @Test func nextChunkLeadingBoundaryConsumedAlone() {
        // If the remainder begins with a boundary run, that run is its own chunk
        // so the following word starts cleanly.
        let session = ActiveSession(fullText: "  next")
        #expect(SessionReconciler.nextChunk(session) == "  ")
    }

    @Test func nextChunkRespectsConsumedCount() {
        // After consuming "world ", the next chunk is "foo" (single trailing word).
        let session = ActiveSession(fullText: "world foo", consumedCount: 6)
        #expect(session.remainder == "foo")
        #expect(SessionReconciler.nextChunk(session) == "foo")
    }

    // MARK: - reconcileTyped

    @Test func reconcileTypedMatchingCharAdvances() {
        let session = ActiveSession(fullText: "world foo")
        #expect(SessionReconciler.reconcileTyped(session, typed: "w") == .advance(1))
    }

    @Test func reconcileTypedDivergingChar() {
        let session = ActiveSession(fullText: "world foo")
        #expect(SessionReconciler.reconcileTyped(session, typed: "x") == .diverged)
    }

    @Test func reconcileTypedEmptyRemainderExhausted() {
        let session = ActiveSession(fullText: "done", consumedCount: 4)
        #expect(SessionReconciler.reconcileTyped(session, typed: "a") == .exhausted)
    }

    @Test func reconcileTypedMatchingSpace() {
        // Whitespace is a normal character for matching purposes.
        let session = ActiveSession(fullText: " more")
        #expect(SessionReconciler.reconcileTyped(session, typed: " ") == .advance(1))
    }
}
