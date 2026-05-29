import AppKit
import ApplicationServices

/// Given a raw focused AX element, find the most usable editable target and read
/// its content (doc 03). The focused element is often a wrapper, not the
/// editable node, so the resolver walks a bounded neighborhood looking for a
/// candidate that has an editable role, a readable value, and a selection range.
///
/// Hard rules:
///  - NEVER read or retain text from a secure field. Secure inputs are detected
///    eagerly and short-circuit everything.
///  - Correctness-or-nothing: when no usable element is found, return a resolution
///    that the watcher maps to `unsupported`.
@MainActor
enum FocusResolver {

    /// The editable element plus the text/selection read from it.
    struct Resolution {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let isSecure: Bool
        /// Full (or AX-windowed) text value; empty if not readable.
        let fullText: String
        let selection: NSRange
        /// Bounded window of text before the caret.
        let precedingText: String
        /// Bounded window of text after the caret.
        let trailingText: String
    }

    // Editable roles we accept. Web roles also report AXTextArea/AXTextField in
    // practice; rich web editors expose AXTextArea on the contenteditable node.
    private static let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        "AXComboBox",
    ]

    /// Resolve the focused element. Returns nil when nothing usable is focused.
    static func resolve(focused: AXUIElement) -> Resolution? {
        // 1. Secure-field short-circuit at the focused node (and the obvious
        //    descent target) before reading any text.
        if isSecureField(focused) {
            return secureResolution(for: focused)
        }

        // 2. Find a usable editable candidate in a bounded neighborhood.
        guard let candidate = findEditable(from: focused) else { return nil }

        // 3. Re-check secure on the resolved candidate — descent could land on
        //    a secure node even if the wrapper looked fine.
        if isSecureField(candidate) {
            return secureResolution(for: candidate)
        }

        let role = AccessibilityBridge.string(candidate, kAXRoleAttribute) ?? ""
        let subrole = AccessibilityBridge.string(candidate, kAXSubroleAttribute)

        // 4. Read text value and selection. Both are required for usability.
        guard let selection = AccessibilityBridge.selectedTextRange(candidate) else { return nil }
        let value = AccessibilityBridge.string(candidate, kAXValueAttribute)
        let fullText = value ?? ""

        // Compute preceding/trailing windows. Prefer slicing the full value by
        // the selection; if the value is missing, try AXStringForRange reads.
        let (preceding, trailing) = sliceAroundCaret(
            element: candidate,
            fullText: fullText,
            haveValue: value != nil,
            selection: selection
        )

        return Resolution(
            element: candidate,
            role: role,
            subrole: subrole,
            isSecure: false,
            fullText: fullText,
            selection: selection,
            precedingText: preceding,
            trailingText: trailing
        )
    }

    // MARK: - Secure detection

    /// True if this element is a secure / password / protected text input.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        if let subrole = AccessibilityBridge.string(element, kAXSubroleAttribute),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return true
        }
        // Some hosts flag protected content without the secure subrole.
        if let protected = AccessibilityBridge.bool(element, "AXProtectedContent"), protected {
            return true
        }
        return false
    }

    private static func secureResolution(for element: AXUIElement) -> Resolution {
        let role = AccessibilityBridge.string(element, kAXRoleAttribute) ?? ""
        let subrole = AccessibilityBridge.string(element, kAXSubroleAttribute)
        // Never read text. Empty windows, empty selection.
        return Resolution(
            element: element,
            role: role,
            subrole: subrole,
            isSecure: true,
            fullText: "",
            selection: NSRange(location: 0, length: 0),
            precedingText: "",
            trailingText: ""
        )
    }

    // MARK: - Candidate search

    /// True if an element looks like a readable editable text node.
    private static func isEditableCandidate(_ element: AXUIElement) -> Bool {
        guard let role = AccessibilityBridge.string(element, kAXRoleAttribute) else { return false }
        guard editableRoles.contains(role) else { return false }
        // Must expose a selection range to be usable.
        guard AccessibilityBridge.selectedTextRange(element) != nil else { return false }
        return true
    }

    /// Walk a bounded neighborhood: the focused node, then its descendants
    /// (breadth-first, depth-capped), then a couple of parents. Returns the
    /// first secure or editable candidate. Secure detection happens in resolve().
    private static func findEditable(from focused: AXUIElement) -> AXUIElement? {
        // Fast path: the focused node itself.
        if isEditableCandidate(focused) { return focused }

        // Bounded breadth-first descent (rich editors mount editable subtree
        // a beat after focus; the poll loop retries, so we keep this cheap).
        var queue: [(element: AXUIElement, depth: Int)] = [(focused, 0)]
        var visited = 0
        let maxVisited = 64
        let maxDepth = 4
        while !queue.isEmpty, visited < maxVisited {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if node != focused, isEditableCandidate(node) { return node }
            if depth < maxDepth {
                for child in AccessibilityBridge.elements(node, kAXChildrenAttribute) {
                    queue.append((child, depth + 1))
                }
            }
        }

        // Limited upward walk — the editable node is sometimes the focused
        // node's ancestor (wrapper focused inside the real field).
        var parent = AccessibilityBridge.element(focused, kAXParentAttribute)
        var hops = 0
        while let p = parent, hops < 3 {
            if isEditableCandidate(p) { return p }
            parent = AccessibilityBridge.element(p, kAXParentAttribute)
            hops += 1
        }

        return nil
    }

    // MARK: - Text windowing

    /// Produce bounded preceding/trailing windows around the caret. The caret is
    /// taken as the selection start (selection.location). Windows: preceding
    /// keeps the TAIL (~1000 chars / ~50 words), trailing keeps a short HEAD
    /// (~200 chars). See doc 06 windowing rules.
    private static func sliceAroundCaret(
        element: AXUIElement,
        fullText: String,
        haveValue: Bool,
        selection: NSRange
    ) -> (preceding: String, trailing: String) {
        let caret = max(0, selection.location)

        if haveValue {
            // Slice the full value by UTF-16 offset (AX ranges are UTF-16).
            let utf16 = Array(fullText.utf16)
            let safeCaret = min(caret, utf16.count)
            let precedingUTF16 = Array(utf16[0..<safeCaret])
            let trailingUTF16 = Array(utf16[safeCaret..<utf16.count])
            let preceding = String(decoding: precedingUTF16, as: UTF16.self)
            let trailing = String(decoding: trailingUTF16, as: UTF16.self)
            return (windowedPreceding(preceding), windowedTrailing(trailing))
        }

        // No whole value (e.g. very large or web fields). Try parameterized
        // sub-range reads for just the windows we need.
        let precedingStart = max(0, caret - 1024)
        let precedingLen = caret - precedingStart
        let precedingRaw = AccessibilityBridge.stringForRange(element, location: precedingStart, length: precedingLen) ?? ""
        let trailingRaw = AccessibilityBridge.stringForRange(element, location: caret, length: 256) ?? ""
        return (windowedPreceding(precedingRaw), windowedTrailing(trailingRaw))
    }

    // MARK: - Local windowing (mirror of ContextWindowing rules, doc 06)
    // Kept local so the resolver does not depend on Support/ load order; the
    // pure rule lives in ContextWindowing and is exercised by tests.

    private static func windowedPreceding(_ text: String) -> String {
        // Keep the tail: at most ~1000 chars AND ~50 words.
        var tail = text
        if tail.count > 1000 {
            tail = String(tail.suffix(1000))
        }
        let words = tail.split(separator: " ", omittingEmptySubsequences: false)
        if words.count > 50 {
            tail = words.suffix(50).joined(separator: " ")
        }
        return tail
    }

    private static func windowedTrailing(_ text: String) -> String {
        // Short head window, ~200 chars.
        if text.count > 200 {
            return String(text.prefix(200))
        }
        return text
    }
}
