#!/bin/bash
# Publishes a signed macOS app as a Sparkle update in this repository.
#
#   tools/publish-app.sh --app-path /ruta/MiApp.app --slug miapp [--notes "Cambios"] [--dry-run] [--skip-notarize]
#
# Order (nothing reaches users until the last step):
#   1. checks: Developer ID signature, Sparkle key matches the app, version is new and higher
#   2. notarize + staple (keychain profile "mac-apps-notary", see README)
#   3. ZIP + Sparkle EdDSA signature
#   4. GitHub Release (draft → upload → verify → publish) and download check
#   5. only then: update apps/<slug>/appcast.xml and push it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="$ROOT/tools/sparkle/bin"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClipMaker}" # notarytool keychain profile for team KQMP2NUSS7
APP_PATH="" SLUG="" NOTES="" DRY_RUN=0 SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --app-path) APP_PATH="$2"; shift 2 ;;
        --slug) SLUG="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --skip-notarize) SKIP_NOTARIZE=1; shift ;;
        *) echo "Opción desconocida: $1" >&2; exit 2 ;;
    esac
done
fail() { echo "❌ $*" >&2; exit 1; }
step() { echo "▶ $*"; }

[ -d "$APP_PATH" ] || fail "No existe la app: $APP_PATH"
[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || fail "--slug debe ser minúsculas/números/guiones (p. ej. mypaste)"
[ -x "$SPARKLE_BIN/sign_update" ] || "$ROOT/tools/setup-sparkle.sh"

PLIST="$APP_PATH/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
APP_NAME="$(read_plist CFBundleName)"
VERSION="$(read_plist CFBundleShortVersionString)"
BUILD="$(read_plist CFBundleVersion)"
MIN_OS="$(read_plist LSMinimumSystemVersion)"
FEED_URL="$(read_plist SUFeedURL)"
APP_PUBLIC_KEY="$(read_plist SUPublicEDKey)"
REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner)"
TAG="$SLUG-v$VERSION"
APP_DIR="$ROOT/apps/$SLUG"
EXPECTED_FEED="https://raw.githubusercontent.com/$REPO/main/apps/$SLUG/appcast.xml"
ZIP_NAME="$APP_NAME-$VERSION.zip"

# ── 1. Checks ────────────────────────────────────────────────────────────────
step "Comprobando $APP_NAME $VERSION (build $BUILD)"
[ -n "$VERSION" ] && [ -n "$BUILD" ] && [ -n "$MIN_OS" ] || fail "Faltan CFBundleShortVersionString/CFBundleVersion/LSMinimumSystemVersion"
[ "$FEED_URL" = "$EXPECTED_FEED" ] || fail "SUFeedURL de la app ($FEED_URL) debe ser $EXPECTED_FEED"
codesign --verify --deep --strict "$APP_PATH" || fail "La firma de la app no es válida"
SIGNATURE_INFO="$(codesign -dvv "$APP_PATH" 2>&1)" # captured first: grep -q in a pipe + pipefail = false failures
[[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application"* ]] || fail "La app no está firmada con Developer ID"
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SLUG" -p 2>/dev/null || true)"
[ -n "$KEYCHAIN_PUBLIC_KEY" ] || fail "No hay clave Sparkle '$SLUG' en el llavero (tools/sparkle/bin/generate_keys --account $SLUG)"
[ "$KEYCHAIN_PUBLIC_KEY" = "$APP_PUBLIC_KEY" ] || fail "SUPublicEDKey de la app no coincide con la clave '$SLUG' del llavero"
LATEST="$(python3 -I "$ROOT/tools/appcast.py" latest --dir "$APP_DIR")"
if [ -n "$LATEST" ]; then
    python3 -I -c "import sys; k=lambda v:[int(p) if p.isdigit() else p for p in v.split('.')]; sys.exit(0 if k('$BUILD')>k('$LATEST') else 1)" \
        || fail "La versión $BUILD debe ser mayor que la última publicada ($LATEST)"
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "Ya existe la release $TAG"; fi
(cd "$ROOT" && git pull --ff-only --quiet) || fail "No se pudo actualizar el repo de actualizaciones"

# One publication at a time: two runs would race when pushing the feed.
LOCK="$ROOT/.publish.lock"
mkdir "$LOCK" 2>/dev/null || fail "Ya hay otra publicación en curso (si no es así, borra $LOCK)"
# Private scratch folder per run (concurrent dry runs must not delete each other's files).
mkdir -p "$ROOT/work"
WORK="$(mktemp -d "$ROOT/work/$TAG.XXXXXX")"
cleanup() { rmdir "$LOCK" 2>/dev/null || true; [ "$DRY_RUN" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
STAGED_APP="$WORK/$(basename "$APP_PATH")"
ditto "$APP_PATH" "$STAGED_APP"

# ── 2. Notarization ─────────────────────────────────────────────────────────
if [ "$SKIP_NOTARIZE" = 1 ]; then
    echo "⚠️  Sin notarizar (--skip-notarize): la primera instalación manual pedirá clic derecho → Abrir."
else
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "Falta el perfil de notarización '$NOTARY_PROFILE' (ver README) o usa --skip-notarize"
    step "Notarizando (puede tardar unos minutos)"
    ditto -c -k --keepParent "$STAGED_APP" "$WORK/notarize.zip"
    SUBMIT_JSON="$(xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    STATUS="$(echo "$SUBMIT_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
    if [ "$STATUS" != "Accepted" ]; then
        SUBMISSION_ID="$(echo "$SUBMIT_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
        fail "Notarización rechazada ($STATUS)"
    fi
    xcrun stapler staple "$STAGED_APP" >/dev/null
    xcrun stapler validate "$STAGED_APP" >/dev/null || fail "No se pudo grapar el ticket de notarización"
    spctl --assess --type execute "$STAGED_APP" || fail "Gatekeeper rechaza la app notarizada"
    rm "$WORK/notarize.zip"
fi

# ── 3. ZIP + Sparkle signature ──────────────────────────────────────────────
step "Empaquetando y firmando para Sparkle"
ZIP="$WORK/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP"
SIGN_OUTPUT="$("$SPARKLE_BIN/sign_update" --account "$SLUG" "$ZIP")"
SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] && [ "$LENGTH" = "$(stat -f%z "$ZIP")" ] || fail "Firma Sparkle inválida"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"

if [ "$DRY_RUN" = 1 ]; then
    echo "✅ Ensayo completo (--dry-run): $ZIP"
    echo "   Se publicaría en $DOWNLOAD_URL"
    exit 0
fi

# ── 4. GitHub Release ───────────────────────────────────────────────────────
step "Creando la release $TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --draft --title "$APP_NAME $VERSION" \
    --notes "${NOTES:-$APP_NAME $VERSION}" >/dev/null
UPLOADED_SIZE="$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name==\"$ZIP_NAME\") | .size")"
if [ "$UPLOADED_SIZE" != "$LENGTH" ]; then
    gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag || true
    fail "El ZIP subido no coincide ($UPLOADED_SIZE ≠ $LENGTH); release borrada"
fi
gh release edit "$TAG" --repo "$REPO" --draft=false >/dev/null
for attempt in 1 2 3 4 5 6; do
    REMOTE_SIZE="$(curl -sIL "$DOWNLOAD_URL" | awk 'tolower($1)=="content-length:" {size=$2} END {gsub("\r","",size); print size}')"
    [ "$REMOTE_SIZE" = "$LENGTH" ] && break
    sleep 5
done
[ "$REMOTE_SIZE" = "$LENGTH" ] || fail "La descarga pública no está disponible todavía; el feed NO se actualizó. Reintenta solo el paso 5."

# ── 5. Feed (last: this is what makes the update visible) ───────────────────
step "Actualizando el feed"
python3 -I "$ROOT/tools/appcast.py" add --dir "$APP_DIR" --app-name "$APP_NAME" --version "$VERSION" --build "$BUILD" \
    --min-os "$MIN_OS" --url "$DOWNLOAD_URL" --length "$LENGTH" --signature "$SIGNATURE" --notes "$NOTES"
# Identity used by installers (AgentsManager) to verify downloads: bundle ID, signing team, Sparkle public key.
APP_NAME="$APP_NAME" SLUG="$SLUG" BUNDLE_ID="$(read_plist CFBundleIdentifier)" \
TEAM_ID="$(echo "$SIGNATURE_INFO" | sed -n 's/^TeamIdentifier=//p')" PUBLIC_KEY="$APP_PUBLIC_KEY" MIN_OS="$MIN_OS" FEED_URL="$FEED_URL" \
python3 -I -c 'import json, os, sys
e = os.environ
json.dump({"name": e["APP_NAME"], "slug": e["SLUG"], "bundleId": e["BUNDLE_ID"], "teamId": e["TEAM_ID"],
           "publicEDKey": e["PUBLIC_KEY"], "minimumSystemVersion": e["MIN_OS"], "feedUrl": e["FEED_URL"]},
          open(sys.argv[1], "w"), indent=2)' "$APP_DIR/app.json"
(cd "$ROOT" && git add "apps/$SLUG" && git commit --quiet -m "$APP_NAME $VERSION" && git push --quiet)

echo "✅ $APP_NAME $VERSION publicada."
echo "   Release: https://github.com/$REPO/releases/tag/$TAG"
echo "   Feed:    $EXPECTED_FEED  (GitHub puede tardar ~5 min en servir el cambio)"
