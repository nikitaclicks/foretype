import Foundation

/// Decides whether a freshly-read focused element is the *same field* as the one
/// we saw last poll, or a genuine focus change — and produces the stable element
/// hash to record in `FocusIdentity` (doc 03).
///
/// Why this exists: `CFHash(AXUIElement)` is normally stable for a given element,
/// but some hosts (notably Chromium/Electron rich editors like ClickUp, which
/// re-render their contenteditable DOM on every keystroke) hand out a brand-new
/// `AXUIElement` — and therefore a new hash — for the *same logical field* on
/// essentially every poll. Treating each as a new field bumps `changeSequence`
/// every 50 ms, which tears the completion pipeline down before it can ever
/// produce a suggestion. So when the hash churns but the field is plainly the
/// same (same pid + a stable structural signature: role, subrole, position), we
/// keep the prior identity instead of minting a new one.
///
/// Pure: no AX, no I/O. The impure signature read lives in `FocusWatcher`.
enum FocusIdentitySequencer {
    /// What we remember about the previously-focused element.
    struct Prior: Equatable {
        let hash: Int?
        let pid: pid_t?
        /// Stable structural signature (role|subrole|x|y|width), or nil if the
        /// element exposes no frame to anchor stability on.
        let signature: String?

        static let none = Prior(hash: nil, pid: nil, signature: nil)
    }

    struct Result: Equatable {
        /// True when this is a genuinely different field (caller bumps the
        /// monotonic `changeSequence` and records the new hash/signature).
        let identityChanged: Bool
        /// The hash to embed in `FocusIdentity.elementHash`: the live hash for a
        /// real change, or the prior (stable) hash when we're collapsing churn.
        let stableHash: Int
    }

    /// Resolve identity for the current read against the prior one.
    static func resolve(hash: Int, pid: pid_t, signature: String?, prior: Prior) -> Result {
        // A different process is unambiguously a different field.
        if prior.pid != pid {
            return Result(identityChanged: true, stableHash: hash)
        }
        // Exact same element hash: same field, fast path.
        if let priorHash = prior.hash, priorHash == hash {
            return Result(identityChanged: false, stableHash: hash)
        }
        // Hash changed, but the structural signature matches the prior one: the
        // host recycled the AX node for the same logical field. Keep the prior
        // hash so the identity (and the freshness token derived from it) is stable.
        if let signature, let priorSignature = prior.signature,
           let priorHash = prior.hash, signature == priorSignature {
            return Result(identityChanged: false, stableHash: priorHash)
        }
        // Otherwise it's a new field.
        return Result(identityChanged: true, stableHash: hash)
    }
}
