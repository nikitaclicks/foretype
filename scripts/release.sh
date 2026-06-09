#!/usr/bin/env bash
# Cut a Foretype release: bump version, build Release (signed), zip, publish to
# GitHub Releases, and refresh the Homebrew cask.
#
#   ./scripts/release.sh 0.1.0            # full release (tags, publishes, updates cask)
#   ./scripts/release.sh 0.1.0 --dry-run  # build + zip + checksum only, no git/gh
#
# Distribution model (AeroSpace-style): the app is NOT notarized. The Homebrew
# cask strips com.apple.quarantine on install so it launches without Gatekeeper
# warnings. We keep signing with the project's real Apple Development identity
# (not ad-hoc) because macOS TCC ties the Accessibility / Input Monitoring grants
# to the signing team + bundle id — so users' permissions persist across updates.
# Override the identity for a future Developer ID cert via SIGN_IDENTITY=...
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# --- Args --------------------------------------------------------------------
VERSION="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
[ "${1:-}" = "--dry-run" ] && { echo "✗ Usage: $0 <version> [--dry-run]"; exit 1; }

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "✗ Usage: $0 <version> [--dry-run]   (version like 0.1.0)"
  exit 1
fi

GH_USER="nikitaclicks"
REPO="$GH_USER/foretype"
APP_NAME="Foretype"
BUNDLE_ID="com.foretype.Foretype"
ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
DIST_DIR="$REPO_ROOT/dist"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
CASK_FILE="$DIST_DIR/Casks/foretype.rb"
PBXPROJ="$REPO_ROOT/${APP_NAME}.xcodeproj/project.pbxproj"
DERIVED="$REPO_ROOT/build/release"
APP="$DERIVED/Build/Products/Release/${APP_NAME}.app"

# --- Preflight ---------------------------------------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ Foretype needs full Xcode to build (not just Command Line Tools)."
  echo "  Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "✗ Not a git repo yet. Publishing needs git + a GitHub remote."
    echo "  Run with --dry-run to build/zip locally, or set up git first:"
    echo "    git init && gh repo create $REPO --public --source=. --remote=origin --push"
    exit 1
  fi
  if [ -n "$(git status --porcelain)" ]; then
    echo "✗ Working tree is dirty. Commit or stash before releasing."
    exit 1
  fi
  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "✗ GitHub CLI not authenticated. Run: gh auth login"
    exit 1
  fi
fi

echo "▸ Releasing $APP_NAME v$VERSION  (dry-run: $DRY_RUN)"

# --- 1. Set version ----------------------------------------------------------
# MARKETING_VERSION drives CFBundleShortVersionString (and the cask version).
# CURRENT_PROJECT_VERSION (CFBundleVersion) is bumped monotonically.
CUR_BUILD=$(grep -m1 -E 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | grep -oE '[0-9]+' | head -1)
NEXT_BUILD=$(( ${CUR_BUILD:-0} + 1 ))
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PBXPROJ"
echo "  · MARKETING_VERSION=$VERSION  CURRENT_PROJECT_VERSION=$NEXT_BUILD"

# --- 2. Build Release --------------------------------------------------------
echo "▸ Building Release…"
rm -rf "$DERIVED"
BUILD_ARGS=(
  -project "${APP_NAME}.xcodeproj"
  -scheme "$APP_NAME"
  -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
)
[ -n "${SIGN_IDENTITY:-}" ] && BUILD_ARGS+=( CODE_SIGN_IDENTITY="$SIGN_IDENTITY" )
xcodebuild "${BUILD_ARGS[@]}" clean build \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

[ -d "$APP" ] || { echo "✗ Build did not produce $APP"; exit 1; }

# --- 3. Verify signature -----------------------------------------------------
echo "▸ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority=Apple' || true

# --- 4. Zip ------------------------------------------------------------------
echo "▸ Packaging ${ZIP_NAME}…"
mkdir -p "$DIST_DIR/Casks"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"   # archive contains Foretype.app at its root

# --- 5. Checksum -------------------------------------------------------------
SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "  · sha256: $SHA"
echo "  · size:   $(du -h "$ZIP_PATH" | awk '{print $1}')"

# --- 6. Refresh the in-repo cask (source of truth) ---------------------------
write_cask() {
  cat > "$CASK_FILE" <<RUBY
cask "foretype" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/${REPO}/releases/download/v#{version}/${APP_NAME}-v#{version}.zip"
  name "Foretype"
  desc "Menu-bar inline autocomplete with ghost text"
  homepage "https://github.com/${REPO}"

  depends_on macos: :sonoma # macOS 14+, matches LSMinimumSystemVersion

  app "${APP_NAME}.app"

  # Not notarized (AeroSpace-style): strip the quarantine flag on install so the
  # app launches without a Gatekeeper "unidentified developer" block.
  postflight do
    system "xattr", "-dr", "com.apple.quarantine", "#{appdir}/${APP_NAME}.app"
  end

  uninstall quit: "${BUNDLE_ID}"

  zap trash: "~/Library/Preferences/${BUNDLE_ID}.plist"
end
RUBY
}
write_cask
echo "  · wrote $CASK_FILE"

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "✓ Dry run complete. Artifact: $ZIP_PATH"
  echo "  Nothing was tagged, published, or pushed."
  exit 0
fi

# --- 7. Publish to GitHub Releases -------------------------------------------
echo "▸ Tagging and publishing…"
git add -A
git commit -m "Release v$VERSION"
git tag "v$VERSION"
git push origin HEAD --tags
gh release create "v$VERSION" "$ZIP_PATH" \
  --repo "$REPO" --title "v$VERSION" --generate-notes

# --- 8. Sync the cask into the tap repo --------------------------------------
if [ -n "${FORETYPE_TAP_DIR:-}" ] && [ -d "$FORETYPE_TAP_DIR" ]; then
  echo "▸ Updating tap at ${FORETYPE_TAP_DIR}…"
  mkdir -p "$FORETYPE_TAP_DIR/Casks"
  cp "$CASK_FILE" "$FORETYPE_TAP_DIR/Casks/foretype.rb"
  git -C "$FORETYPE_TAP_DIR" add Casks/foretype.rb
  git -C "$FORETYPE_TAP_DIR" commit -m "foretype $VERSION"
  git -C "$FORETYPE_TAP_DIR" push
  echo "  · tap updated"
else
  echo
  echo "ℹ Tap not auto-updated (set FORETYPE_TAP_DIR=~/dev/homebrew-tap to sync + push it)."
  echo "  Copy dist/Casks/foretype.rb into the tap's Casks/ and push, or update by hand:"
  echo "    version \"$VERSION\""
  echo "    sha256 \"$SHA\""
fi

echo
echo "✓ Released v$VERSION → https://github.com/${REPO}/releases/tag/v$VERSION"
echo "  Install: brew install --cask ${GH_USER}/tap/foretype"
