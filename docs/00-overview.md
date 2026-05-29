# 00 — Product Overview

## What Foretype is

Foretype is a macOS menu bar utility that offers inline text completions
system-wide. Wherever the user is typing into an editable text field — a
browser, a notes app, a chat client, a code editor — Foretype predicts a short
continuation and shows it as faded **ghost text** immediately after the caret.
Pressing `Tab` accepts the next word of that prediction; the remainder stays
visible and can be accepted word by word, or the prediction updates as the user
keeps typing.

The completion comes from a language model. Foretype supports two backends and
the user picks one in settings:

- **Apple Intelligence** (default when available): the on-device system model
  via the Foundation Models framework. No network, no API key.
- **OpenAI-compatible HTTP**: any server exposing `POST /v1/chat/completions`.
  Used for local model servers and remote providers alike.

## Who it is for

People who type a lot and want low-friction, context-aware autocomplete in
arbitrary apps, without copying text into a separate assistant window. Privacy-
conscious users can run entirely on-device with Apple Intelligence or a local
HTTP server.

## Goals

- **Universal.** Work in as many standard macOS text fields as Accessibility
  allows, without per-app integrations.
- **Unobtrusive.** Ghost text never steals focus, never blocks typing, and
  disappears the moment it is no longer relevant.
- **Fast.** The pipeline from keystroke to ghost text should feel immediate.
  Stale predictions must never appear.
- **Private by default.** The default backend runs on-device. Nothing leaves
  the machine unless the user configures a remote HTTP endpoint.
- **Frugal.** A small, comprehensible codebase with no third-party
  dependencies. Every subsystem should be explainable in a paragraph.

## Non-goals

These are explicitly **out of scope** for this implementation. Do not build
them.

- **No local model runtime.** No bundled inference engine, no model downloads,
  no GGUF/weights management. On-device generation is provided solely by Apple
  Intelligence; everything else goes over HTTP.
- **No screenshot / OCR / visual context.** Foretype does not capture the
  screen. It reasons only about text it can read from the focused field via
  Accessibility. Consequently it does **not** request Screen Recording
  permission.
- **No multi-line / paragraph generation as a feature surface.** Completions
  are short continuations (a handful of words up to a short phrase), not essay
  drafting.
- **No cloud account, telemetry, or analytics.** No sign-in, no usage
  reporting.
- **No auto-update / distribution machinery** in the first implementation
  (no update feed, no signing pipeline specced here). Build a normal app
  bundle that runs locally.
- **No clipboard scraping** and **no user-profile personalization** in prompts.
- **No Windows/Linux/iOS.** macOS only.

## What "done" looks like

A user can:

1. Launch the app; it appears only in the menu bar.
2. Grant Accessibility and Input Monitoring when guided.
3. Pick a backend (Apple Intelligence, or enter an HTTP endpoint).
4. Type in a normal text field and see ghost-text completions appear.
5. Press `Tab` to accept a word at a time; keep typing to refine.
6. Turn Foretype off globally, or disable it for specific apps.

## Core principles (apply throughout)

1. **Predictability over cleverness.** Prefer a simple polling loop with
   bounded latency over event-driven heuristics that work "most of the time."
   Accessibility notifications are unreliable across host apps; a steady poll
   gives eventual consistency you can reason about.

2. **Never show a stale completion.** Every prediction is tagged with a
   generation token derived from the focused field and its content. When a
   model result returns, it is shown only if the world still matches. Otherwise
   it is dropped silently.

3. **Pure rules live apart from side effects.** Prompt construction, text
   normalization, availability evaluation, app-rule matching, and session
   reconciliation are pure functions with no I/O. They are the most heavily
   tested part of the system. Stateful coordinators orchestrate them but
   contain little logic of their own.

4. **The coordinator depends on capabilities, not concretes.** The completion
   state machine talks to narrow protocols ("give me focus snapshots", "insert
   this text", "generate from this request"). Concrete macOS implementations
   sit behind those protocols so the state machine is testable in isolation.

5. **Get out of the way.** When in doubt — focus uncertain, field unsupported,
   geometry unreliable, permission missing — show nothing rather than something
   wrong or mispositioned.
