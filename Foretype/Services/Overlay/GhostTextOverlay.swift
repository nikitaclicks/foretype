import AppKit
import SwiftUI

/// Renders the faded ghost-text preview in a borderless, non-activating overlay
/// panel that floats above all content and never takes focus (doc 08).
///
/// The overlay is a *dumb renderer*: it never decides whether to show, only how.
/// All show/hide decisions come from the coordinator. It owns exactly one
/// reusable `NSPanel` hosting a reused `NSHostingView<GhostTextView>`; updates
/// swap the view's text/geometry rather than rebuilding the hosting view.
@MainActor
final class GhostTextOverlay: OverlayPresenting {
    private let settings: SettingsProviding

    /// The single reusable overlay window.
    private let panel: NSPanel
    /// The reused SwiftUI host; on update we mutate its `rootView`.
    private let hostingView: NSHostingView<GhostTextView>

    /// Padding between the caret's trailing edge and the start of the ghost text,
    /// so it reads as a continuation rather than colliding with the caret.
    private let leadingGap: CGFloat = 1

    init(settings: SettingsProviding) {
        self.settings = settings

        // Start with an empty placeholder root; real content is pushed on show.
        let initialView = GhostTextView(
            text: "",
            fontSize: 14,
            color: .secondary,
            wrapWidth: nil
        )
        let hosting = NSHostingView(rootView: initialView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        self.hostingView = hosting

        // Non-activating, borderless panel: showing it never steals key focus.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true            // click-through to host app
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Above the menu bar, follows the user across Spaces and full-screen apps.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        self.panel = panel
    }

    // MARK: - OverlayPresenting

    func show(_ text: String, geometry: OverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "empty text")
            return
        }
        render(text: text, geometry: geometry)
        panel.orderFrontRegardless()   // appear without activating
    }

    func reposition(geometry: OverlayGeometry) {
        // Move/resize without changing text (word-by-word acceptance, caret
        // correction). Reuse the currently-rendered text.
        let current = hostingView.rootView.text
        guard !current.isEmpty else { return }
        render(text: current, geometry: geometry)
    }

    func hide(reason: String) {
        // `reason` is intentionally accepted for the coordinator's logging
        // contract; the renderer simply orders out and clears.
        panel.orderOut(nil)
        hostingView.rootView = GhostTextView(
            text: "",
            fontSize: hostingView.rootView.fontSize,
            color: hostingView.rootView.color,
            wrapWidth: nil
        )
    }

    // MARK: - Layout

    /// Lay out the panel for the given text + geometry and push fresh content
    /// into the reused hosting view.
    private func render(text: String, geometry: OverlayGeometry) {
        let fontSize = fontSize(for: geometry)
        let font = NSFont.systemFont(ofSize: fontSize)
        let color = resolvedColor()

        let caretRect = geometry.caretRect
        // Anchor at the caret's trailing edge, on the caret line.
        let originX = caretRect.maxX + leadingGap

        // Decide whether the text overflows the right screen edge; if so, wrap
        // back to the field's left edge (kept deliberately simple).
        let screenMaxX = screenMaxX(for: caretRect)
        let availableWidth = max(0, screenMaxX - originX)
        let measuredWidth = measuredWidth(text, font: font)

        let wrapWidth: CGFloat?
        let frameWidth: CGFloat
        let frameOriginX: CGFloat

        if measuredWidth <= availableWidth || availableWidth <= 0 {
            // Fits on the line: single-line run sized to the text.
            wrapWidth = nil
            frameWidth = max(1, measuredWidth)
            frameOriginX = originX
        } else {
            // Overflow: wrap. Prefer the field's left edge as the wrap origin so
            // continuation lines align with the field; fall back to the caret.
            let wrapOriginX = geometry.fieldRect?.minX ?? originX
            let wrapRight = geometry.fieldRect?.maxX ?? screenMaxX
            let width = max(1, wrapRight - wrapOriginX)
            wrapWidth = width
            frameWidth = width
            frameOriginX = wrapOriginX
        }

        // Update the reused hosting view's root (no rebuild).
        hostingView.rootView = GhostTextView(
            text: text,
            fontSize: fontSize,
            color: color,
            wrapWidth: wrapWidth
        )

        // Size the panel to fit the (possibly wrapped) content.
        let fittingHeight = hostingView.fittingSize.height
        let lineHeight = max(caretRect.height, font.ascender - font.descender)
        let frameHeight = max(lineHeight, fittingHeight)

        // Vertically align to the caret line. In Cocoa screen coords the origin
        // is bottom-left, so match the caret's bottom edge.
        let frameOriginY = caretRect.minY

        let frame = NSRect(
            x: frameOriginX,
            y: frameOriginY,
            width: frameWidth,
            height: frameHeight
        )
        panel.setFrame(frame, display: true)
    }

    /// Derive the ghost-text point size from caret height, clamped to a sane
    /// range; clamp more tightly when caret quality is `estimated`.
    private func fontSize(for geometry: OverlayGeometry) -> CGFloat {
        let raw = geometry.caretRect.height * 0.78
        let lower: CGFloat = 14
        let upper: CGFloat = geometry.quality == .estimated ? 16 : 24
        guard raw.isFinite, raw > 0 else { return lower }
        return min(upper, max(lower, raw))
    }

    /// Resolve the configured ghost-text color, defaulting to secondary label.
    private func resolvedColor() -> Color {
        if let hex = settings.current.ghostTextColorHex,
           let nsColor = NSColor(hex: hex) {
            return Color(nsColor)
        }
        return Color(nsColor: .secondaryLabelColor)
    }

    /// The right edge of the screen containing the caret, for overflow detection.
    private func screenMaxX(for caretRect: CGRect) -> CGFloat {
        let containing = NSScreen.screens.first { $0.frame.intersects(caretRect) }
        let screen = containing ?? NSScreen.main
        return screen?.frame.maxX ?? caretRect.maxX
    }

    /// Measure the single-line rendered width of `text` in `font`.
    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        return ceil(attributed.size().width) + leadingGap
    }
}

// MARK: - Hex color parsing

private extension NSColor {
    /// Parse a `#RGB`, `#RRGGBB`, or `#RRGGBBAA` hex string into an sRGB color.
    /// Returns nil on any malformed input so the overlay degrades to the default.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }

        let chars = Array(s)
        let expanded: String
        switch chars.count {
        case 3:
            // #RGB → #RRGGBB
            expanded = chars.map { "\($0)\($0)" }.joined()
        case 6, 8:
            expanded = s
        default:
            return nil
        }

        guard let value = UInt64(expanded, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if expanded.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
