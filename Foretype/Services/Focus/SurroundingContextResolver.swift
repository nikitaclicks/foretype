import AppKit
import ApplicationServices

/// Gathers bounded, read-only *surrounding* content from the accessibility tree
/// around the focused field (doc 06), so completions can be relevant to what is
/// in the app (e.g. a ClickUp task's title, description, and earlier comments)
/// rather than only the text inside the one field. AX-only: no screen capture,
/// no OCR (doc 00 non-goal).
///
/// This is NOT pure and NOT cheap — it walks a bounded slice of the AX tree — so
/// the coordinator calls it lazily at generation time and caches the result per
/// focus identity. The 50 ms focus poll never touches this. All math (dedup,
/// caps, overlap removal) lives in the pure `SurroundingContextWindowing`; this
/// type is a thin, tolerant AX shell, mirroring `FocusResolver`.
///
/// Hard rules (same spirit as `FocusResolver`):
///  - NEVER read text from a secure field anywhere in the walk.
///  - NEVER re-collect the focused field's own subtree (would duplicate the
///    in-progress text already sent as `precedingText`/`trailingText`).
///  - Correctness-or-nothing: any failure returns "", a safe degrade.
@MainActor
enum SurroundingContextResolver {

    /// Fraction of the page (web-area) area an ancestor must reach to be picked
    /// as the content container. The visually-dominant task panel crosses this;
    /// thin sidebars / toolbars do not. Most likely field-tuning dial.
    private static let containerAreaFraction: CGFloat = 0.35
    /// Maximum parent hops while choosing a container. Web composers nest deep:
    /// in ClickUp (chat thread / task panel in Chrome) the editable sits ~11–14
    /// ancestors below the content panel, so a shallow cap stops at a sparse
    /// sub-wrapper that excludes the surrounding messages/description. Verified
    /// against ClickUp chat: 8 missed the conversation; this reaches the panel
    /// that contains it.
    private static let maxClimbHops = 20
    /// Hard cap on nodes visited during collection — the primary cost lever for
    /// the main-thread walk (lower if a hitch is observed on field entry).
    private static let maxVisitedNodes = 1500
    /// Depth cap for the collection BFS. Web composers nest deep, and the
    /// container is anchored at the thread/panel (not the shallow web-area root),
    /// so the budget is spent descending toward the conversation rather than on
    /// app chrome. Generous because ClickUp's chat thread nests well past 12.
    private static let maxDepth = 30

    /// Roles whose own text we capture (and do not recurse into).
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading"]
    /// Editable roles whose value we capture when they are NOT the focused field.
    private static let valueTextRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
    /// UI-chrome roles we neither read nor recurse into (button labels, icon alt
    /// text, menus, etc. are noise that degrades completions).
    private static let skipRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXImage", "AXMenu", "AXMenuItem", "AXMenuBar", "AXToolbar", "AXTabGroup",
        "AXTab", "AXSlider", "AXIncrementor", "AXScrollBar", "AXDisclosureTriangle",
    ]

    /// Gather surrounding content relative to an already-resolved editable
    /// element. Returns "" on any failure.
    static func gather(focusedEditable: AXUIElement) -> String {
        let focusedHash = AccessibilityBridge.hash(focusedEditable)

        // The composer's own on-screen frame (AX top-left coords). Drives the
        // spatial scoping in `collect`; nil for a degenerate tree, which falls
        // back to the area-fraction container heuristic with no spatial filter.
        let composerFrame = AccessibilityBridge.frame(focusedEditable)

        guard let scope = resolveScope(from: focusedEditable, composerFrame: composerFrame) else {
            CompletionCoordinator.ctxDiag("resolver: scope=nil")
            return ""
        }

        CompletionCoordinator.ctxDiag("resolver: containerRole=\(AccessibilityBridge.string(scope.container, kAXRoleAttribute as String) ?? "?") webArea=\(scope.webArea != nil) composerFrame=\(composerFrame.map { "\($0)" } ?? "nil")")

        var fragments: [String] = []

        // Cheap, high-value first fragment: the web-area / document title, which
        // for a ClickUp task/chat typically carries the task or channel name.
        // Exempt from the spatial filter — always wanted.
        if let webArea = scope.webArea,
           let title = AccessibilityBridge.string(webArea, kAXTitleAttribute as String),
           !title.isEmpty {
            fragments.append(title)
        }

        collect(in: scope.container, focusedHash: focusedHash, composerFrame: composerFrame, into: &fragments)

        return SurroundingContextWindowing.assemble(fragments: fragments)
    }

    // MARK: - Container scoping

    private struct Scope {
        let container: AXUIElement
        let webArea: AXUIElement?
    }

    private struct Ancestor {
        let element: AXUIElement
        let frame: CGRect?
        let area: CGFloat
        let isWebArea: Bool
    }

    /// Walk up from the focused field to choose the container BFS-walks for text.
    ///
    /// When the composer's frame is known, pick the *thread/panel* container: the
    /// nearest ancestor whose frame reaches above the composer far enough to cover
    /// the spatial above-window (so its subtree holds the messages/description
    /// above the composer). Anchoring there — rather than at the web-area root —
    /// keeps BFS tight (small breadth, shallow depth) even though web composers
    /// sit deep in the DOM: starting at the root would spend the visit/depth
    /// budget on shallow app chrome (nav, headers) before reaching the deeply
    /// nested conversation, which is exactly how the conversation gets missed.
    /// Spatial proximity in `collect` then carves the relevant region out.
    ///
    /// Without a composer frame (degenerate tree), fall back to the legacy
    /// heuristic: the first (closest) ancestor whose frame area is a large
    /// fraction of the page — the content region holding the messages/description
    /// above the composer, not the thin sidebar/nav. Either way, stop at the web
    /// area (never climbing into browser chrome) and at `maxClimbHops`.
    private static func resolveScope(from start: AXUIElement, composerFrame: CGRect?) -> Scope? {
        var chain: [Ancestor] = []
        var webArea: AXUIElement?
        var node = AccessibilityBridge.element(start, kAXParentAttribute)
        var hops = 0
        while let current = node, hops < maxClimbHops {
            let role = AccessibilityBridge.string(current, kAXRoleAttribute as String) ?? ""
            let frame = AccessibilityBridge.frame(current)
            let area = frame.map { $0.width * $0.height } ?? 0
            let isWebArea = (role == "AXWebArea")
            chain.append(Ancestor(element: current, frame: frame, area: area, isWebArea: isWebArea))
            if isWebArea {
                webArea = current
                break  // do not climb past the page into browser chrome
            }
            node = AccessibilityBridge.element(current, kAXParentAttribute)
            hops += 1
        }

        guard !chain.isEmpty else { return nil }

        // Composer geometry available: anchor at the thread/panel container (the
        // closest ancestor whose top reaches above the composer's above-window),
        // then let the spatial filter in `collect` scope the result.
        if let composerFrame, !composerFrame.isEmpty {
            let aboveTop = composerFrame.minY
                - SurroundingContextWindowing.verticalWindowAboveFactor * composerFrame.height
            if let panel = chain.first(where: { ancestor in
                guard !ancestor.isWebArea, let f = ancestor.frame, !f.isEmpty else { return false }
                return f.minY <= aboveTop
            }) {
                return Scope(container: panel.element, webArea: webArea)
            }
            // No ancestor reaches above the window (composer near page top, or
            // frameless ancestors): use the broadest reachable container.
            let container = webArea ?? chain.last?.element
            return container.map { Scope(container: $0, webArea: webArea) }
        }

        // No composer frame: legacy visually-dominant-region heuristic, no filter.
        let pageArea = (webArea != nil ? chain.last?.area : nil) ?? chain.map(\.area).max() ?? 0
        let nonWeb = chain.filter { !$0.isWebArea }

        // No frames to reason about, or no non-web-area ancestor: fall back.
        guard pageArea > 0, !nonWeb.isEmpty else {
            let container = nonWeb.first?.element ?? chain.first?.element
            return container.map { Scope(container: $0, webArea: webArea) }
        }

        let threshold = pageArea * containerAreaFraction
        if let chosen = nonWeb.first(where: { $0.area >= threshold }) {
            return Scope(container: chosen.element, webArea: webArea)
        }

        // Nothing crossed the fraction (rare): a fixed mid-depth non-web ancestor
        // is still far better scoped than the whole page.
        let fallback = nonWeb[min(4, nonWeb.count - 1)].element
        return Scope(container: fallback, webArea: webArea)
    }

    // MARK: - Collection

    /// Bounded BFS over the container, capturing text from text-bearing nodes in
    /// document order. Skips the focused field's subtree and any secure node.
    /// When `composerFrame` is non-nil, a captured text node is kept only if it is
    /// spatially related to the composer (same column, within the vertical
    /// window) — this scopes the panel container down to the actual
    /// conversation/thread around the composer. nil disables the filter.
    private static func collect(
        in container: AXUIElement,
        focusedHash: Int,
        composerFrame: CGRect?,
        into fragments: inout [String]
    ) {
        var queue: [(element: AXUIElement, depth: Int)] = [(container, 0)]
        var visited = 0

        while !queue.isEmpty,
              visited < maxVisitedNodes,
              fragments.count < SurroundingContextWindowing.maxFragments {
            let (node, depth) = queue.removeFirst()
            visited += 1

            // Exclude the focused field and everything under it.
            if AccessibilityBridge.hash(node) == focusedHash { continue }
            // Never read from a secure node or its subtree.
            if FocusResolver.isSecureField(node) { continue }

            let role = AccessibilityBridge.string(node, kAXRoleAttribute as String) ?? ""

            if textRoles.contains(role) {
                if let text = textValue(of: node), isNear(node, composerFrame) {
                    fragments.append(text)
                }
                continue  // leaf text; no useful children
            }
            if valueTextRoles.contains(role) {
                if let value = AccessibilityBridge.string(node, kAXValueAttribute as String),
                   !value.isEmpty, isNear(node, composerFrame) {
                    fragments.append(value)
                }
                continue
            }
            if skipRoles.contains(role) { continue }

            // Structural / unknown container: descend.
            if depth < maxDepth {
                for child in AccessibilityBridge.elements(node, kAXChildrenAttribute as String) {
                    queue.append((child, depth + 1))
                }
            }
        }

        CompletionCoordinator.ctxDiag("collect: visited=\(visited)/\(maxVisitedNodes) kept=\(fragments.count) queueLeft=\(queue.count)")
    }

    /// Spatial gate for a captured text node. Cheap pre-checks have already
    /// passed, so we read this node's frame (one AX call per *kept-candidate*
    /// node, not per visited node) and delegate the pure geometry to
    /// `SurroundingContextWindowing`. With no composer frame the filter is off.
    private static func isNear(_ node: AXUIElement, _ composerFrame: CGRect?) -> Bool {
        guard let composerFrame else { return true }
        guard let nodeFrame = AccessibilityBridge.frame(node) else { return true }
        return SurroundingContextWindowing.isSpatiallyRelated(candidate: nodeFrame, composer: composerFrame)
    }

    /// Read a text node's content: prefer AXValue, fall back to AXTitle.
    private static func textValue(of element: AXUIElement) -> String? {
        if let value = AccessibilityBridge.string(element, kAXValueAttribute as String), !value.isEmpty {
            return value
        }
        if let title = AccessibilityBridge.string(element, kAXTitleAttribute as String), !title.isEmpty {
            return title
        }
        return nil
    }
}
