#!/usr/bin/env bash
# Build Foretype to a visible in-repo path and (re)launch it.
#
# Why Apple Development signing (set in the project): macOS TCC ties the
# Accessibility / Input Monitoring grants to the app's *designated requirement*
# (signing team + bundle id) when signed with a real identity. The permissions
# you grant once PERSIST across rebuilds — unlike ad-hoc ("-") signing, which
# re-prompts every build because its cdhash changes each time. The build path is
# irrelevant to TCC, so moving it here (build/ instead of .build/) is safe.
set -euo pipefail

cd "$(dirname "$0")"

DERIVED="$PWD/build"                                   # visible (no leading dot)
APP="$DERIVED/Build/Products/Debug/Foretype.app"
LINK="$PWD/Foretype.app"                               # convenience symlink at repo root

echo "▸ Building (Apple Development signed)…"
xcodebuild \
  -project Foretype.xcodeproj \
  -scheme Foretype \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

# Keep a stable, double-clickable artifact at the repo root pointing at the build.
ln -sfn "$APP" "$LINK"

# Quit any running instance so the freshly-built binary takes over.
if pgrep -x Foretype >/dev/null; then
  echo "▸ Quitting running instance…"
  pkill -x Foretype || true
  sleep 1
fi

echo "▸ Launching $APP"
open "$APP"
echo "▸ Foretype is in the menu bar (top-right). Artifact: ./Foretype.app  ·  Quit: pkill -x Foretype"
