#!/usr/bin/env bash
# Regenerate Foretype/Assets.xcassets/AppIcon.appiconset from the Swift renderer.
# Renders a 1024 master, downscales to every macOS slice, writes Contents.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$ROOT/Foretype/Assets.xcassets/AppIcon.appiconset"
MASTER="$(mktemp -t foretype-icon).png"

mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$MASTER" >/dev/null

# size -> filename
emit() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }
emit 16   icon_16.png
emit 32   icon_32.png
emit 64   icon_64.png
emit 128  icon_128.png
emit 256  icon_256.png
emit 512  icon_512.png
cp "$MASTER" "$ICONSET/icon_1024.png"
rm -f "$MASTER"

cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "Wrote $ICONSET"
