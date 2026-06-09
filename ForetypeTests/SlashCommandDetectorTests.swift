import Testing
import Foundation
@testable import Foretype

/// Tests for `SlashCommandDetector` — suppression while typing a bare slash
/// command, resuming once the next word begins.
struct SlashCommandDetectorTests {

    @Test func bareCommandIsInProgress() {
        #expect(SlashCommandDetector.isCommandInProgress(precedingText: "/help"))
    }

    @Test func loneSlashIsInProgress() {
        #expect(SlashCommandDetector.isCommandInProgress(precedingText: "/"))
    }

    @Test func resumesOnceSpaceFollowsCommand() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "/help me"))
    }

    @Test func trailingSpaceAfterCommandResumes() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "/giphy "))
    }

    @Test func slashMidLineIsNotACommand() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "not /a command"))
    }

    @Test func emptyTextIsNotACommand() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: ""))
    }

    @Test func plainTextIsNotACommand() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "hello world"))
    }

    @Test func commandOnLaterLineIsInProgress() {
        // Only the current line (after the last newline) matters.
        #expect(SlashCommandDetector.isCommandInProgress(precedingText: "hello\n/giphy"))
    }

    @Test func commandWithWordOnLaterLineResumes() {
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "hello\n/giphy cat"))
    }

    @Test func indentedSlashIsNotCommand() {
        // Slash commands sit at column 0; indentation means it's ordinary text.
        #expect(!SlashCommandDetector.isCommandInProgress(precedingText: "  /help"))
    }
}
