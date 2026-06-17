# Contributing to Foretype

Thanks for your interest in improving Foretype. This document covers how to get
set up, what the project values, and how to submit changes.

## Getting started

1. Read [`docs/00-overview.md`](docs/00-overview.md) and
   [`docs/01-architecture.md`](docs/01-architecture.md) — they explain the goals,
   non-goals, and the module map. [`AGENTS.md`](AGENTS.md) lists the hard
   invariants to respect.
2. Build and run with `./run.sh` (see the README), or open
   `Foretype.xcodeproj` in Xcode and run the `Foretype` scheme.
3. Run the tests: the `ForetypeTests` target in Xcode, or
   `xcodebuild test -project Foretype.xcodeproj -scheme Foretype -destination 'platform=macOS'`.

## Release signing (maintainers)

Local dev (`./run.sh`) signs with an Apple Development cert — fine for your own
machine. But that's a *development* signature (it carries `get-task-allow`), and
macOS AMFI **kills it on any other Mac** with a code-signing SIGKILL (launchd
termination `(27,1,9)`). So `scripts/build.sh` re-signs the shipped bundle with a
separate, portable identity before packaging.

The default identity is a **stable self-signed code-signing certificate** named
`Foretype Self-Signed`. Because the signature is keyed to the cert (not the binary
hash), macOS keeps users' Accessibility / Input Monitoring grants across version
updates. Create it once:

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Foretype Self-Signed`; Identity Type: **Self Signed Root**;
   Certificate Type: **Code Signing**. Create it.
3. **Export it (cert + private key) as a `.p12` and back it up** (e.g. a password
   manager). This cert is the anchor of permission persistence — if it's lost,
   every user must re-grant permissions on the next release. To sign releases from
   another machine, import the same `.p12` there.

Then `./scripts/build.sh <version>` will re-sign with it automatically and verify
the shipped bundle is neither dev-signed nor carrying `get-task-allow`.

If you don't want to manage a cert, run with `DIST_SIGN_IDENTITY=-` for plain
ad-hoc signing. It runs on any Mac too, but its hash changes every build, so users
must re-grant Accessibility / Input Monitoring on **every update**.

## Design principles

These are load-bearing — please keep changes consistent with them:

- **No third-party dependencies.** Foretype uses only Apple frameworks. Don't
  add Swift packages without a documented, compelling reason.
- **Privacy by default.** No telemetry, analytics, screen capture, or clipboard
  scraping. The default backend runs on-device.
- **Pure rules live apart from side effects.** Prompt construction, text
  normalization, availability evaluation, and reconciliation are pure functions
  and the most heavily tested part of the system. Keep new logic testable.
- **Never show a stale completion.** Respect the generation-token discipline in
  doc 05 — a result is shown only if the world still matches.
- **Get out of the way.** When focus, geometry, or permissions are uncertain,
  show nothing rather than something wrong.

## Making a change

1. Fork the repo and create a branch off `main`.
2. Keep changes focused; prefer small, reviewable PRs.
3. Match the surrounding code style — naming, comment density, and the
   `@MainActor` / `Sendable` boundaries described in docs 01 and 11.
4. Add or update tests for behavior changes. Pure logic should have unit tests.
5. Make sure the project builds with no new warnings and tests pass.
6. Write a clear PR description: what changed, why, and how you verified it.

## Reporting bugs

Open an issue with: macOS version, whether you're on Apple Intelligence or an
HTTP backend, the app or text field involved, and steps to reproduce. Since
Foretype reads focused-field text, please redact anything sensitive.

## License

By contributing, you agree that your contributions will be licensed under the
[GNU Affero General Public License v3.0](LICENSE), consistent with the rest of
the project.
