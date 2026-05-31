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

# --- Preflight ---------------------------------------------------------------
# Foretype is a developer build with no prebuilt/signed download yet
# (distribution + notarization are out of scope for now), so building it
# requires full Xcode — not just the Command Line Tools. Fail with guidance
# instead of a cryptic xcodebuild error.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ Foretype needs Xcode to build, and it isn't available."
  if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
    echo "  You have the Command Line Tools, but not full Xcode."
    echo "    1. Install Xcode from the App Store (free)."
    echo "    2. Point the toolchain at it:"
    echo "         sudo xcode-select -s /Applications/Xcode.app"
    echo "    3. Re-run ./run.sh"
  else
    echo "  Install Xcode from the App Store (free), then re-run ./run.sh"
  fi
  echo
  echo "  (There is no signed, double-clickable download yet — this script"
  echo "   builds Foretype from source on your machine.)"
  exit 1
fi

if [ ! -d "Foretype.xcodeproj" ]; then
  echo "✗ Run this from the Foretype repo root (Foretype.xcodeproj not found here)."
  exit 1
fi

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
