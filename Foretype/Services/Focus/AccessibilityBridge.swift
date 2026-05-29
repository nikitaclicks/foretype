import AppKit
import ApplicationServices

/// Low-level Accessibility (AX) bridging, doc 03. Isolated so the rest of the
/// codebase never touches raw `AX*` C APIs directly. Every read is tolerant: a
/// missing attribute is a normal outcome, not an error, and nothing is ever
/// force-unwrapped. Also owns the AX(top-left, y-down) → Cocoa(bottom-left,
/// y-up) coordinate conversion, accounting for multi-display arrangements.
@MainActor
enum AccessibilityBridge {

    // MARK: - System focus & frontmost app

    /// The system-wide focused UI element, or nil if none / not trusted.
    static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let raw = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // Safe: type checked above.
        return (raw as! AXUIElement)
    }

    /// Frontmost application's (bundleID, pid, localized name). Any field may be nil.
    static func frontmostApp() -> (bundleID: String?, pid: pid_t, name: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.bundleIdentifier, app.processIdentifier, app.localizedName)
    }

    // MARK: - Tolerant attribute reads

    /// Raw attribute copy. Returns nil for any non-success status.
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    /// String attribute (e.g. role, subrole, value). nil if missing or not a string.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let raw = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    /// AXUIElement attribute (e.g. parent). nil if missing or wrong type.
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    /// Array-of-elements attribute (e.g. children). Empty array if missing.
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let raw = copyAttribute(element, attribute) else { return [] }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        let array = (raw as! CFArray) as NSArray
        return array.compactMap { obj -> AXUIElement? in
            let ref = obj as CFTypeRef
            guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
            return (ref as! AXUIElement)
        }
    }

    /// Bool attribute (e.g. AXEnabled, a protected flag). nil if missing.
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let raw = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    /// The selected text range as an NSRange. nil if missing or not an AXValue range.
    static func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = copyAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        guard range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// Number of characters in the element (AXNumberOfCharacters). nil if missing.
    static func numberOfCharacters(_ element: AXUIElement) -> Int? {
        guard let raw = copyAttribute(element, kAXNumberOfCharactersAttribute) else { return nil }
        guard CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
        var n = 0
        guard CFNumberGetValue((raw as! CFNumber), .nsIntegerType, &n) else { return nil }
        return n >= 0 ? n : nil
    }

    /// The element's frame in AX (top-left) screen coordinates. nil if unavailable.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posRaw = copyAttribute(element, kAXPositionAttribute),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              let sizeRaw = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        let posValue = posRaw as! AXValue
        let sizeValue = sizeRaw as! AXValue
        guard AXValueGetType(posValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Parameterized attribute: bounds for range

    /// `AXBoundsForRange` for a sub-range, returned in AX (top-left) coords.
    /// nil if the attribute is unsupported or the range is invalid.
    static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0, length >= 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard err == .success, let raw = result else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        // AX sometimes returns zero/empty rects for collapsed/offscreen ranges.
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }

    /// `AXStringForRange` — used to read a sub-range of text. nil if unsupported.
    static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length >= 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard err == .success, let raw = result, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    // MARK: - Identity

    /// A stable-ish hash of the element (CFHash). May recycle across elements,
    /// which is exactly why the snapshot also carries a monotonic changeSequence.
    static func hash(_ element: AXUIElement) -> Int {
        Int(bitPattern: CFHash(element))
    }

    // MARK: - Coordinate conversion (AX top-left/y-down → Cocoa bottom-left/y-up)

    /// Convert an AX-screen rect (origin top-left, y grows downward) into Cocoa
    /// global screen coordinates (origin bottom-left of the primary display, y
    /// grows upward). Returns nil if the rect does not intersect any real screen.
    static func axRectToCocoa(_ axRect: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        // The full desktop height is measured from the primary (menu-bar) screen,
        // which defines the y-origin for the AX coordinate space.
        let primaryHeight = primary.frame.height
        let cocoaY = primaryHeight - axRect.origin.y - axRect.height
        let cocoaRect = CGRect(x: axRect.origin.x, y: cocoaY, width: axRect.width, height: axRect.height)

        // Validate: the converted rect must land on (or touch) a real screen.
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(cocoaRect) || $0.frame.contains(cocoaRect.origin) }
        guard onScreen else { return nil }
        return cocoaRect
    }

    // MARK: - Trust

    /// Whether the process is currently AX-trusted. (Permission management lives
    /// in PermissionMonitor; this is a convenience for early bailout.)
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
