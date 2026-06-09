#!/usr/bin/env bash
# Build + sign + package Foretype locally so you can TEST it. Produces the
# release artifact (dist/Foretype-v<version>.zip) and refreshes the cask, but
# publishes NOTHING. Run scripts/release.sh <version> afterwards to publish it.
#
#   ./scripts/build.sh 0.1.0
#
# Signing/notarization rationale lives in scripts/release.sh's header. Override
# the signing identity for a future Developer ID cert via SIGN_IDENTITY=...
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

VERSION="${1:-}"
valid_version "$VERSION" || { echo "✗ Usage: $0 <version>   (e.g. 0.1.0)"; exit 1; }
set_artifact_vars
require_xcode

echo "▸ Building $APP_NAME v$VERSION (local, not published)"

# --- 1. Set version ----------------------------------------------------------
# MARKETING_VERSION drives CFBundleShortVersionString (and the cask version).
# CURRENT_PROJECT_VERSION (CFBundleVersion) is bumped monotonically per build.
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

# --- 4. Zip (archive contains Foretype.app at its root) ----------------------
echo "▸ Packaging ${ZIP_NAME}…"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

# --- 5. Checksum + cask + manifest -------------------------------------------
SHA=$(sha_of "$ZIP_PATH")
write_cask "$VERSION" "$SHA"
cat > "$MANIFEST" <<EOF
VERSION=$VERSION
BUILD=$NEXT_BUILD
SHA=$SHA
ZIP=$ZIP_NAME
EOF
echo "  · sha256: $SHA"
echo "  · size:   $(du -h "$ZIP_PATH" | awk '{print $1}')"
echo "  · cask:   $CASK_FILE"

echo
echo "✓ Built v$VERSION — nothing published."
echo "  Test it:  open \"$APP\""
echo "  Publish:  ./scripts/release.sh $VERSION"
