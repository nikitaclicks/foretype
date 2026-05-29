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
