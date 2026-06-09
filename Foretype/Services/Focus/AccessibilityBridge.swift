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

    // MARK: - Enhanced accessibility opt-in (Chromium / Electron)

    /// Ask an application to expose its full accessibility tree by setting
    /// `AXManualAccessibility` on its application-level element.
    ///
    /// Chromium-based apps (Chrome, Edge, Brave, Arc, …) and Electron apps (Slack,
    /// VS Code, Discord, …) build their inner / web AX tree only when an assistive
    /// client opts in this way; until then their editable web fields are invisible
    /// to AX and resolve to nothing — which is why completion appears to "not work"
    /// in Chrome while working in native apps. Native apps don't recognize the
    /// attribute and ignore the set, so this is safe to call for any app.
    /// Best-effort: the return status is intentionally ignored, and the tree mounts
    /// a beat later, so the poll loop picks up the now-resolvable field on a
    /// subsequent tick (doc 03, "App-specific quirks").
    ///
    /// For NATIVE apps we set ONLY `AXManualAccessibility`, never
    /// `AXEnhancedUserInterface`: the latter can provoke window move/resize side
    /// effects in native AppKit apps, and we apply this to every frontmost app.
    ///
    /// For Chromium **browsers** we additionally set `AXEnhancedUserInterface`.
    /// Under `AXManualAccessibility` alone, recent Chrome exposes only a partial
    /// tree — control roles + field frames, but degenerate text geometry (no
    /// `AXSelectedTextMarkerRange`, zero-size `AXBoundsForRange`, no static-text
    /// runs) — so the caret can't reach `.derived` and the field is unsupported.
    /// `AXEnhancedUserInterface` promotes the browser to full accessibility incl.
    /// text geometry. Gated to browsers so native AppKit apps are unaffected.
    /// (Electron apps like the ClickUp desktop app expose full geometry under
    /// `AXManualAccessibility` already, so they don't need this.)
    static func enableEnhancedAccessibility(pid: pid_t, bundleID: String) {
        guard pid > 0 else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if isChromiumBrowser(bundleID) {
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Chromium-based **browsers** (not Electron apps), which need
    /// `AXEnhancedUserInterface` to expose full text geometry (see above).
    private static let chromiumBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    private static func isChromiumBrowser(_ bundleID: String) -> Bool {
        chromiumBrowserBundleIDs.contains(bundleID)
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

    // MARK: - Parameterized attribute: bounds via text markers (web hosts)

    /// Caret/selection bounds via the **text-marker** API, for web hosts
    /// (Chromium / WebKit) that don't map NSRange offsets to geometry through
    /// `AXBoundsForRange` (they return empty / zero-height rects). Reads the live
    /// `AXSelectedTextMarkerRange` — opaque; passed straight back through without
    /// inspecting it — and asks for its bounds via `AXBoundsForTextMarkerRange`.
    /// Walks up to an ancestor (the web area) because the selection marker range
    /// is often exposed there rather than on the field itself. Returns AX
    /// (top-left) coords, or nil if the host has no text markers / no usable rect.
    static func boundsForSelectedTextMarkerRange(of start: AXUIElement) -> CGRect? {
        var node: AXUIElement? = start
        var hops = 0
        while let current = node, hops < 5 {
            if let markerRange = copyAttribute(current, "AXSelectedTextMarkerRange"),
               let rect = boundsForTextMarkerRange(current, markerRange) {
                return rect
            }
            node = element(current, kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    /// Ask `element` for the bounds of an opaque `AXTextMarkerRange`.
    private static func boundsForTextMarkerRange(_ element: AXUIElement, _ markerRange: CFTypeRef) -> CGRect? {
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForTextMarkerRange" as CFString,
            markerRange,
            &result
        )
        guard err == .success, let raw = result else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
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

    // MARK: - Parameterized attribute: font for range

    /// The font applied at a sub-range, read from `AXAttributedStringForRange`'s
    /// `AXFont` attribute. Lets the overlay render ghost text in the host field's
    /// actual font (family + point size) instead of guessing from caret height
    /// (doc 08). Returns `(name, pointSize)`; `name` may be nil if only a size is
    /// exposed. nil when the host doesn't support attributed strings (common for
    /// some web fields) — callers fall back to the caret-height heuristic.
    static func fontForRange(_ element: AXUIElement, location: Int, length: Int) -> (name: String?, pointSize: CGFloat)? {
        guard location >= 0, length > 0 else { return nil }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        )
        guard err == .success, let raw = result,
              CFGetTypeID(raw) == CFAttributedStringGetTypeID() else { return nil }
        let attributed = raw as! CFAttributedString
        guard CFAttributedStringGetLength(attributed) > 0 else { return nil }

        // The AXFont attribute value is a dictionary keyed by AXFontName /
        // AXFontSize. The ApplicationServices symbol constants import as
        // `Unmanaged<CFString>`, so we use the raw key strings directly — matching
        // the marker-range / enhanced-AX keys elsewhere in this file.
        guard let fontRaw = CFAttributedStringGetAttribute(attributed, 0, "AXFont" as CFString, nil),
              CFGetTypeID(fontRaw) == CFDictionaryGetTypeID() else { return nil }
        let dict = fontRaw as! CFDictionary as NSDictionary

        let name = dict["AXFontName"] as? String

        var pointSize: CGFloat?
        if let n = dict["AXFontSize"] as? NSNumber {
            pointSize = CGFloat(truncating: n)
        }
        guard let size = pointSize, size.isFinite, size > 0 else { return nil }
        return (name: name, pointSize: size)
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
