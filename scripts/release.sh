#!/usr/bin/env bash
# Publish an ALREADY-BUILT Foretype artifact to GitHub Releases and refresh the
# Homebrew cask/tap. Run scripts/build.sh <version> FIRST to produce + test it.
#
#   ./scripts/build.sh   0.1.0   # build + sign + package locally, then test
#   ./scripts/release.sh 0.1.0   # publish that exact artifact
#
# Distribution model (AeroSpace-style): the app is NOT notarized. The Homebrew
# cask strips com.apple.quarantine on install so it launches without Gatekeeper
# warnings. The build signs with the project's real Apple Development identity
# (not ad-hoc) so macOS keeps the Accessibility / Input Monitoring grants across
# updates — TCC keys them to the signing team + bundle id.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

VERSION="${1:-}"
valid_version "$VERSION" || { echo "✗ Usage: $0 <version>   (e.g. 0.1.0)"; exit 1; }
set_artifact_vars

# --- Preflight: the artifact must exist and match what we'll publish ---------
if [ ! -f "$ZIP_PATH" ] || [ ! -f "$MANIFEST" ]; then
  echo "✗ No local build for v$VERSION (expected $ZIP_PATH)."
  echo "  Build + test it first:  ./scripts/build.sh $VERSION"
  exit 1
fi
# shellcheck disable=SC1090
source "$MANIFEST"   # → SHA, BUILD, ZIP (VERSION already set from the arg)
if [ "$(sha_of "$ZIP_PATH")" != "$SHA" ]; then
  echo "✗ Artifact changed since it was built (sha mismatch)."
  echo "  Rebuild:  ./scripts/build.sh $VERSION"
  exit 1
fi
if ! grep -q "sha256 \"$SHA\"" "$CASK_FILE" || ! grep -q "version \"$VERSION\"" "$CASK_FILE"; then
  echo "✗ dist/Casks/foretype.rb doesn't match the built artifact."
  echo "  Rebuild:  ./scripts/build.sh $VERSION"
  exit 1
fi

# --- Preflight: git + gh -----------------------------------------------------
if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "✗ Not a git repo yet. Publishing needs git + a GitHub remote:"
  echo "    git init && gh repo create $REPO --public --source=. --remote=origin --push"
  exit 1
fi
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "✗ GitHub CLI not authenticated. Run: gh auth login"
  exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
   || gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ v$VERSION already exists (git tag or GitHub release). Bump the version."
  exit 1
fi

echo "▸ Publishing $APP_NAME v$VERSION  (build $BUILD, sha ${SHA:0:12}…)"

# --- Commit the version bump + cask (only those files) -----------------------
git add "$PBXPROJ" "$CASK_FILE"
if git diff --cached --quiet; then
  echo "  · version + cask already committed; continuing"
else
  git commit -m "Release v$VERSION"
fi
git tag "v$VERSION"
git push origin HEAD --tags

# --- GitHub Release (uploads the artifact you built & tested) ----------------
gh release create "v$VERSION" "$ZIP_PATH" \
  --repo "$REPO" --title "v$VERSION" --generate-notes

# --- Sync the cask into the tap repo (so `brew install` matches the release) -
# This MUST happen or installs fail with a sha mismatch — the cask brew reads
# lives in the tap, not this repo. Defaults to ~/dev/homebrew-tap (see lib.sh).
if [ -d "$TAP_DIR/.git" ]; then
  echo "▸ Syncing cask into tap ($TAP_DIR)…"
  mkdir -p "$TAP_DIR/Casks"
  cp "$CASK_FILE" "$TAP_DIR/Casks/foretype.rb"
  git -C "$TAP_DIR" add Casks/foretype.rb
  if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "  · tap already up to date"
  else
    git -C "$TAP_DIR" commit -q -m "foretype $VERSION"
  fi
  git -C "$TAP_DIR" push -q
  echo "  · tap pushed"
else
  echo
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║ ⚠  TAP NOT SYNCED — \`brew install\` WILL FAIL with a sha mismatch.  ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo "  No tap clone found at: $TAP_DIR"
  echo "  Clone it there (then future releases sync automatically):"
  echo "    git clone git@github.com:${GH_USER}/homebrew-${TAP_NAME}.git \"$TAP_DIR\""
  echo "  …or sync this release by hand now:"
  echo "    cp dist/Casks/foretype.rb \"\$TAP\"/Casks/ && \\"
  echo "      git -C \"\$TAP\" commit -am 'foretype $VERSION' && git -C \"\$TAP\" push"
  echo "    (where \$TAP is your local homebrew-tap clone)"
fi

echo
echo "✓ Released v$VERSION → https://github.com/${REPO}/releases/tag/v$VERSION"
echo "  Install: brew update && brew install --cask ${GH_USER}/${TAP_NAME}/foretype"
