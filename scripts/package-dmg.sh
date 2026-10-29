#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Usage Tracker.app"

if [[ ! -d "$APP" ]]; then
    echo "No se encontró Usage Tracker.app. Ejecuta antes ./build.sh release." >&2
    exit 1
fi

VERSION="${1:-$("/usr/libexec/PlistBuddy" -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
if [[ -z "$VERSION" ]]; then
    echo "No se pudo determinar la versión." >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Usage Tracker.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/release"
DMG="$ROOT/release/UsageTracker-${VERSION}.dmg"

rm -f "$DMG" "$DMG.sha256"
hdiutil create \
    -volname "Usage Tracker" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ DMG: $DMG"
