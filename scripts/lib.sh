#!/usr/bin/env bash
# Shared config + helpers for scripts/build.sh and scripts/release.sh.
# The caller must `cd` to the repo root and set REPO_ROOT before sourcing this.

GH_USER="nikitaclicks"
REPO="$GH_USER/foretype"
TAP_NAME="tap"                # → brew install --cask $GH_USER/$TAP_NAME/foretype
APP_NAME="Foretype"
BUNDLE_ID="com.foretype.Foretype"

# Local clone of the tap repo (github.com/$GH_USER/homebrew-$TAP_NAME). release.sh
# syncs the cask here and pushes it so `brew install` matches the release. Defaults
# to ~/dev/homebrew-tap; override by exporting FORETYPE_TAP_DIR=/some/path.
TAP_DIR="${FORETYPE_TAP_DIR:-$HOME/dev/homebrew-tap}"

DIST_DIR="$REPO_ROOT/dist"
CASK_FILE="$DIST_DIR/Casks/foretype.rb"
PBXPROJ="$REPO_ROOT/${APP_NAME}.xcodeproj/project.pbxproj"
DERIVED="$REPO_ROOT/build/release"
APP="$DERIVED/Build/Products/Release/${APP_NAME}.app"

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Per-version artifact paths. Call once VERSION is known.
set_artifact_vars() {
  ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
  ZIP_PATH="$DIST_DIR/$ZIP_NAME"
  MANIFEST="$DIST_DIR/.build-${VERSION}.env"   # build metadata, gitignored
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

require_xcode() {
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "✗ Foretype needs full Xcode to build (not just Command Line Tools)."
    echo "  Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
    exit 1
  fi
}

# write_cask <version> <sha256> — regenerate dist/Casks/foretype.rb (source of truth).
write_cask() {
  local v="$1" sha="$2"
  mkdir -p "$DIST_DIR/Casks"
  cat > "$CASK_FILE" <<RUBY
cask "foretype" do
  version "${v}"
  sha256 "${sha}"

  url "https://github.com/${REPO}/releases/download/v#{version}/${APP_NAME}-v#{version}.zip"
  name "Foretype"
  desc "Menu-bar inline autocomplete with ghost text"
  homepage "https://github.com/${REPO}"

  depends_on macos: :sonoma # macOS 14+, matches LSMinimumSystemVersion

  app "${APP_NAME}.app"

  # Not notarized: the bundle is signed with a stable self-signed certificate,
  # so strip the quarantine flag on install so the app launches without a
  # Gatekeeper "unidentified developer" block.
  postflight do
    system "xattr", "-dr", "com.apple.quarantine", "#{appdir}/${APP_NAME}.app"
  end

  uninstall quit: "${BUNDLE_ID}"

  zap trash: "~/Library/Preferences/${BUNDLE_ID}.plist"
end
RUBY
}
