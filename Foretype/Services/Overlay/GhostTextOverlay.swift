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
            fontName: nil,
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
            fontName: hostingView.rootView.fontName,
            fontSize: hostingView.rootView.fontSize,
            color: hostingView.rootView.color,
            wrapWidth: nil
        )
    }

    // MARK: - Layout

    /// Lay out the panel for the given text + geometry and push fresh content
    /// into the reused hosting view.
    private func render(text: String, geometry: OverlayGeometry) {
        let color = resolvedColor(geometry: geometry)
        let caretRect = geometry.caretRect

        // Resolve the ghost font from the host field when AX exposed it (family +
        // point size), else fall back to the caret-height heuristic. Matching the
        // real font is what makes the preview line up; see doc 08.
        let ghostFont: NSFont
        let viewFontName: String?
        if let cf = geometry.font, let named = cf.name.flatMap({ NSFont(name: $0, size: cf.pointSize) }) {
            ghostFont = named            // real family + size
            viewFontName = cf.name
        } else if let cf = geometry.font {
            ghostFont = NSFont.systemFont(ofSize: cf.pointSize)   // real size, system family
            viewFontName = nil
        } else {
            ghostFont = NSFont.systemFont(ofSize: fontSize(for: geometry))  // nothing known
            viewFontName = nil
        }
        let usedFontSize = ghostFont.pointSize

        // Optional fine-tune nudges. Both default to 0 — vertical placement is now
        // computed from the font's metrics (see `baselineAlignedY`), not a magic
        // constant. They remain overridable for edge cases, then relaunch:
        //   defaults write com.foretype.Foretype ghostVerticalOffset 0
        //   defaults write com.foretype.Foretype ghostHorizontalOffset 0
        let defaults = UserDefaults.standard
        // Read tolerantly: `defaults write … ghostVerticalOffset 2` stores a
        // STRING, which `as? Double` would silently drop (falling back to the
        // default). `double(forKey:)` coerces numeric strings, so honor the
        // override whenever the key is present in any numeric form.
        func tunable(_ key: String, default fallback: CGFloat) -> CGFloat {
            guard defaults.object(forKey: key) != nil else { return fallback }
            return CGFloat(defaults.double(forKey: key))
        }
        let vOffset = tunable("ghostVerticalOffset", default: 0)
        let hOffset = tunable("ghostHorizontalOffset", default: 0)

        // Anchor at the caret's trailing edge, on the caret line.
        let originX = caretRect.maxX + leadingGap + hOffset

        // Wrap back to the field's left edge if the run would overflow the screen.
        let screenMaxX = screenMaxX(for: caretRect)
        let availableWidth = max(0, screenMaxX - originX)
        let measured = measuredWidth(text, font: ghostFont)

        let wrapWidth: CGFloat?
        let frameWidth: CGFloat
        let frameOriginX: CGFloat
        if measured <= availableWidth || availableWidth <= 0 {
            wrapWidth = nil
            frameWidth = max(1, measured)
            frameOriginX = originX
        } else {
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
            fontName: viewFontName,
            fontSize: usedFontSize,
            color: color,
            wrapWidth: wrapWidth
        )

        let frameHeight = max(1, hostingView.fittingSize.height)
        // Lay out at the final width so the baseline query below is accurate.
        hostingView.frame = NSRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        hostingView.layoutSubtreeIfNeeded()

        // Align the ghost text's first-line baseline to the caret line's baseline,
        // computed from the ghost font's metrics — replaces the old fixed -14 nudge.
        let frameOriginY = baselineAlignedY(
            caretRect: caretRect,
            font: ghostFont,
            frameHeight: frameHeight
        ) + vOffset

        let frame = NSRect(
            x: frameOriginX,
            y: frameOriginY,
            width: frameWidth,
            height: frameHeight
        )
        panel.setFrame(frame, display: true)

        diag(caretRect: caretRect, font: ghostFont, viewFontName: viewFontName,
             hadAXFont: geometry.font != nil, quality: geometry.quality,
             frameHeight: frameHeight, frameOriginY: frameOriginY)
    }

    /// TEMPORARY file-based diagnostic for overlay vertical alignment, gated by
    /// `defaults write com.foretype.Foretype ghostDiag -bool YES`. Writes only
    /// structural geometry (no field text) to /tmp/foretype-ghostdiag.log.
    private func diag(caretRect: CGRect, font: NSFont, viewFontName: String?,
                      hadAXFont: Bool, quality: CaretQuality, frameHeight: CGFloat,
                      frameOriginY: CGFloat) {
        guard UserDefaults.standard.bool(forKey: "ghostDiag") else { return }
        let baselineFromTop = hostingView.firstBaselineOffsetFromTop
        let renderedBaseline = frameOriginY + (frameHeight - baselineFromTop)
        let ascent = font.ascender
        let descent = -font.descender
        let targetBaseline = caretRect.minY + (caretRect.height - (ascent + descent)) / 2 + descent
        let line = """
        caret=(x:\(r(caretRect.minX)) y:\(r(caretRect.minY)) w:\(r(caretRect.width)) h:\(r(caretRect.height))) \
        quality=\(quality) axFont=\(hadAXFont) font=\(viewFontName ?? "system")@\(r(font.pointSize)) \
        ascent=\(r(ascent)) descent=\(r(descent)) lineHeight=\(r(font.ascender - font.descender + font.leading)) \
        frameH=\(r(frameHeight)) baselineFromTop=\(r(baselineFromTop)) \
        targetBaselineY=\(r(targetBaseline)) frameOriginY=\(r(frameOriginY)) renderedBaselineY=\(r(renderedBaseline))

        """
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/foretype-ghostdiag.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func r(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    /// The panel's bottom-left y (Cocoa screen coords) that lands the ghost text's
    /// first-line baseline on the caret line's baseline. The host baseline is
    /// derived by centering the ghost font's glyph box in the caret rect (robust
    /// to caret rects that include line leading), and the rendered baseline is
    /// located via the hosting view's reported first-baseline offset. Falls back
    /// to centering the panel on the caret box if the baseline isn't reported.
    private func baselineAlignedY(caretRect: CGRect, font: NSFont, frameHeight: CGFloat) -> CGFloat {
        let ascent = font.ascender              // > 0, above baseline
        let descent = -font.descender           // make positive, below baseline
        let boxHeight = ascent + descent
        let targetBaselineY = caretRect.minY + (caretRect.height - boxHeight) / 2 + descent

        let baselineFromTop = hostingView.firstBaselineOffsetFromTop
        if baselineFromTop.isFinite, baselineFromTop > 0 {
            // rendered baseline (screen y) = frameOriginY + frameHeight - baselineFromTop
            return targetBaselineY - (frameHeight - baselineFromTop)
        }
        // Fallback: center the whole run on the caret box.
        return caretRect.midY - frameHeight / 2
    }

    /// Derive the ghost-text point size from caret height, clamped to a sane
    /// range; clamp more tightly when caret quality is `estimated`. Used only as
    /// the fallback when AX exposes no font for the field.
    private func fontSize(for geometry: OverlayGeometry) -> CGFloat {
        let raw = geometry.caretRect.height * 0.78
        let lower: CGFloat = 14
        let upper: CGFloat = geometry.quality == .estimated ? 16 : 24
        guard raw.isFinite, raw > 0 else { return lower }
        return min(upper, max(lower, raw))
    }

    /// Resolve the ghost-text color so the suggestion stays visible against the
    /// host background. A user-configured override wins; otherwise we adopt the
    /// host field's own text color (read from AX) dimmed to a placeholder, since
    /// it is guaranteed to contrast the host background; falling back to the
    /// system secondary label color when AX exposes no color (doc 08).
    private func resolvedColor(geometry: OverlayGeometry) -> Color {
        if let hex = settings.current.ghostTextColorHex,
           let nsColor = NSColor(hex: hex) {
            return Color(nsColor)
        }
        if let host = geometry.color {
            // Dim to ~50% so the suggestion reads as a ghost, not committed text.
            // The transparent panel composites this over the host background, so
            // dimmed-black-on-light and dimmed-white-on-dark both stay legible.
            return Color(.sRGB, red: host.red, green: host.green,
                         blue: host.blue, opacity: host.alpha * 0.5)
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
