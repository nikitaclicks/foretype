# 02 — Permissions

Foretype needs exactly **two** macOS privacy permissions. It must never request
a third.

| Permission | Why it is needed | API family |
| --- | --- | --- |
| **Accessibility** | Read which text field is focused, its text around the caret, the selection range, and caret screen geometry — across other apps. | `AXIsProcessTrusted`, `AXIsProcessTrustedWithOptions`, the `AX*` element/attribute API. |
| **Input Monitoring** | Install a global keyboard event tap to observe typing and detect the `Tab` accept gesture. | `CGPreflightListenEventAccess`, `CGRequestListenEventAccess`, `CGEvent` tap API. |

There is **no Screen Recording** permission, because there is no screen capture
or OCR anywhere in the product.

## PermissionMonitor

A single `PermissionMonitor` service owns permission state. It:

- Exposes the current grant state for each permission as observable booleans.
- Polls grant state on a timer (≈2 s) using the **preflight / non-prompting**
  checks (`AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`), so it can
  detect grants made directly in System Settings without nagging the user.
- Publishes a change when either grant flips, so the coordinator can enable or
  disable the affected stream and the menu bar can update.

Polling (rather than relying on notifications) is deliberate: a user typically
grants these in System Settings while the app is already running, and macOS does
not reliably notify the app. The poll picks it up within one interval.

## Requesting permissions

Permissions are requested **only in response to an explicit user action**
(clicking "Enable…" in onboarding or the menu bar), never silently at launch.

- **Accessibility:** call `AXIsProcessTrustedWithOptions` with the
  prompt option set, which opens the system prompt and deep-links to the
  Accessibility pane. The grant usually takes effect without relaunch, but the
  UI should not assume instant effect — the poll confirms it.
- **Input Monitoring:** call `CGRequestListenEventAccess()`, which triggers the
  system prompt for the Input Monitoring pane.

If a deep prompt is unavailable, fall back to opening the relevant System
Settings privacy pane via its `x-apple.systempreferences:` URL and guide the
user with on-screen text.

## Behavior in each permission state

The app must run and be useful-to-configure regardless of grant state.

- **Neither granted:** App launches, shows its menu bar item, and the menu bar
  surfaces a clear "Permissions needed" section with one action per missing
  permission. No focus tracking, no keyboard tap, no completions.
- **Accessibility only:** Focus and geometry work, but with no keyboard tap
  there is no trigger and no accept gesture, so completions stay disabled. The
  coordinator reports a disabled reason; the menu bar still prompts for Input
  Monitoring.
- **Input Monitoring only:** Keyboard events arrive but there is no focus/text
  context to complete against. Completions disabled with a reason.
- **Both granted:** Fully functional. The coordinator transitions out of its
  disabled state on the next focus snapshot.

When a permission is revoked at runtime, the dependent service tears down its
OS resource (e.g. the event tap is invalidated) and the coordinator returns to
`disabled`. When it is re-granted, the service re-installs and the coordinator
re-enables — all driven by the `PermissionMonitor` publisher, with no relaunch.

## First-run onboarding

On first launch, show a small onboarding window (this is the *only* time a
window appears automatically). It should:

1. Explain in one sentence what Foretype does.
2. Walk through granting Accessibility, then Input Monitoring, each with an
   "Enable…" button that triggers the request and a live status indicator that
   flips to "Granted" when the poll confirms it.
3. Let the user pick a backend: Apple Intelligence (if available on this Mac) or
   OpenAI-compatible (with fields to enter base URL / model / optional key).
4. Finish into the running, menu-bar-only state.

Onboarding can be re-opened later from settings. The app must degrade
gracefully if the user closes onboarding early — it simply remains in a
disabled state and keeps prompting from the menu bar.

## Invariants

- Never start the keyboard tap or read cross-app Accessibility data without the
  corresponding grant; doing so silently fails and wastes cycles.
- Never request a permission the product does not use.
- Permission state is owned only by `PermissionMonitor`; other services observe
  it rather than calling the OS checks themselves.
