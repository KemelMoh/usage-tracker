#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="release"
OPEN=0

for arg in "$@"; do
    case "$arg" in
        --open) OPEN=1 ;;
        debug|release) CONFIG="$arg" ;;
        *)
            echo "Uso: ./build.sh [debug|release] [--open]" >&2
            exit 1
            ;;
    esac
done

APP="$ROOT/Usage Tracker.app"
BIN="$ROOT/.build/$CONFIG/UsageTracker"

echo "→ Compilando Usage Tracker ($CONFIG)…"
swift build -c "$CONFIG" --product UsageTracker

if [[ ! -x "$BIN" ]]; then
    echo "No se encontró el binario en $BIN" >&2
    exit 1
fi

echo "→ Creando Usage Tracker.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/UsageTracker"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -d "$ROOT/Resources/ProviderIcons" ]]; then
    mkdir -p "$APP/Contents/Resources/ProviderIcons"
    cp "$ROOT/Resources/ProviderIcons"/*.png "$APP/Contents/Resources/ProviderIcons/"
fi

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ Firmando (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
    echo "Aviso: no se pudo firmar ad-hoc. La app puede seguir abriéndose, pero macOS pedirá permisos de nuevo." >&2
}

echo "✓ Listo: $APP"
echo "  Abre con: open \"$APP\""

if [[ "$OPEN" -eq 1 ]]; then
    open "$APP"
fi
