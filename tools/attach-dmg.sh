#!/bin/bash
# Attaches a first-install DMG to a version already published with tools/publish-app.sh.
#
#   tools/attach-dmg.sh --slug miapp --dmg /ruta/MiApp-1.2.0.dmg
#
# Uploads the DMG to the release <slug>-v<version>, checks the public download, then records url, length
# and sha256 under "dmg" in apps/<slug>/releases.json (installers such as AgentsManager use it).
# The Sparkle feed does not change: updates keep using the signed ZIP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="" DMG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) SLUG="$2"; shift 2 ;;
        --dmg) DMG="$2"; shift 2 ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done
fail() { echo "❌ $*" >&2; exit 1; }

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || fail "--slug debe ser minúsculas/números/guiones"
[ -f "$DMG" ] || fail "No existe el DMG: $DMG"
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper rechaza el DMG (¿sin notarizar?)"

# Version and build come from the app inside, so the DMG can only be attached to its own release.
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -1)"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
VERSION="$(read_plist CFBundleShortVersionString)" BUILD="$(read_plist CFBundleVersion)"
hdiutil detach "$MOUNT" -quiet || true
rmdir "$MOUNT" 2>/dev/null || true
[ -n "$VERSION" ] || fail "El DMG no contiene una app con versión"

REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
TAG="$SLUG-v$VERSION"
NAME="$(basename "$DMG")"
LENGTH="$(stat -f%z "$DMG")"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
URL="https://github.com/$REPO/releases/download/$TAG/$NAME"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || fail "No existe la release $TAG: publícala antes con tools/publish-app.sh"

echo "▶ Subiendo $NAME a $TAG"
gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
for attempt in 1 2 3 4 5 6; do
    REMOTE_SIZE="$(curl -sIL "$URL" | awk 'tolower($1)=="content-length:" {size=$2} END {gsub("\r","",size); print size}')"
    [ "$REMOTE_SIZE" = "$LENGTH" ] && break
    sleep 5
done
[ "$REMOTE_SIZE" = "$LENGTH" ] || fail "La descarga pública del DMG no está disponible todavía; releases.json NO se actualizó"

(cd "$ROOT" && git pull --ff-only --quiet)
python3 -I "$ROOT/tools/appcast.py" attach-dmg --dir "$ROOT/apps/$SLUG" --build "$BUILD" --url "$URL" --length "$LENGTH" --sha256 "$SHA256"
(cd "$ROOT" && git add "apps/$SLUG/releases.json" && git commit --quiet -m "$SLUG $VERSION: DMG de instalación" && git push --quiet)
echo "✅ Instalador: $URL"
