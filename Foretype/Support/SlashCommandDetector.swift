import Foundation

/// Detects when the caret sits inside a bare slash-command token (e.g. `/help`).
/// Many apps (Slack, ClickUp, Discord) interpret a line that begins with `/` as a
/// command and show their own command picker; an inline completion there is just
/// noise. We suppress while the user is still typing the command token and resume
/// the moment they move past it (type the next word). PURE — no I/O, no state.
enum SlashCommandDetector {
    /// True when the current line (the text after the last newline in
    /// `precedingText`) starts with `/` and contains no whitespace yet. Resumes
    /// as soon as a space follows the command, so `/help` is suppressed but
    /// `/help me` is not. Slash commands sit at column 0, so leading indentation
    /// is intentionally NOT trimmed.
    static func isCommandInProgress(precedingText: String) -> Bool {
        let line = precedingText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last ?? Substring(precedingText)
        guard line.first == "/" else { return false }
        return !line.contains(where: { $0.isWhitespace })
    }
}
