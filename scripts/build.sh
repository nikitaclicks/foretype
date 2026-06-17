#!/usr/bin/env bash
# Build + sign + package Foretype locally so you can TEST it. Produces the
# release artifact (dist/Foretype-v<version>.zip) and refreshes the cask, but
# publishes NOTHING. Run scripts/release.sh <version> afterwards to publish it.
#
#   ./scripts/build.sh 0.1.0
#
# Signing/notarization rationale lives in scripts/release.sh's header. The
# shipped bundle is re-signed for distribution (step 2b); override that identity
# via DIST_SIGN_IDENTITY=... (e.g. "-" for ad-hoc, or a future Developer ID cert).
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

# --- 2b. Re-sign for distribution (portable identity, no get-task-allow) ------
# xcodebuild signs with the project's Apple Development cert — a *development*
# signature that carries com.apple.security.get-task-allow. That runs on THIS
# machine but AMFI kills it on any other Mac (launchd termination (27,1,9), a
# codesigning SIGKILL), which is why a copied build never launches. Re-sign the
# shipped bundle with a non-development identity and drop the entitlements
# (omitting --entitlements removes get-task-allow; the app needs none — its
# Accessibility / Input Monitoring access is granted via TCC, not entitlements).
#
# Default identity is the stable self-signed "Foretype Self-Signed" cert (see
# CONTRIBUTING.md) — keyed to a cert, not a binary hash, so macOS keeps users'
# permission grants across version updates. Override with DIST_SIGN_IDENTITY=-
# for plain ad-hoc (runs everywhere too, but re-prompts on every update). The app
# has no embedded frameworks/dylibs, so a single non-deep re-sign is sufficient.
DIST_ID="${DIST_SIGN_IDENTITY:-Foretype Self-Signed}"
echo "▸ Re-signing for distribution as: $DIST_ID"
codesign --force --options runtime --timestamp=none --sign "$DIST_ID" "$APP"

# --- 3. Verify signature -----------------------------------------------------
echo "▸ Verifying signature…"
codesign --verify --strict --verbose=2 "$APP"
# Guard against shipping a build that would SIGKILL on other Macs: it must not be
# a development signature and must not carry get-task-allow.
if codesign -dvv "$APP" 2>&1 | grep -q 'Apple Development'; then
  echo "✗ Still signed with Apple Development — would SIGKILL on other Macs"; exit 1
fi
if codesign -d --entitlements - "$APP" 2>&1 | grep -q 'get-task-allow'; then
  echo "✗ get-task-allow still present — would SIGKILL on other Macs"; exit 1
fi
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Authority|Signature' || true

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
