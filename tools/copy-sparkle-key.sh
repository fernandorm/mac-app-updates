#!/bin/bash
# Copies an app's private Sparkle key from the keychain to the clipboard, to paste it into the
# password manager as a backup. The clipboard is cleared after a few seconds if it still holds the key.
#
#   tools/copy-sparkle-key.sh <slug> [segundos]      p. ej. tools/copy-sparkle-key.sh mymremoteng
#
# Restore on another Mac: paste the key into a file and run
#   tools/sparkle/bin/generate_keys --account <slug> -f archivo && rm archivo
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="$ROOT/tools/sparkle/bin"
SLUG="${1:?Uso: tools/copy-sparkle-key.sh <slug> [segundos]}"
SECONDS_TO_CLEAR="${2:-60}"

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "❌ El slug debe ser minúsculas/números/guiones (p. ej. mypaste)" >&2; exit 2; }
[[ "$SECONDS_TO_CLEAR" =~ ^[0-9]+$ ]] || { echo "❌ Los segundos deben ser un número" >&2; exit 2; }
[ -x "$SPARKLE_BIN/generate_keys" ] || "$ROOT/tools/setup-sparkle.sh"

# generate_keys only exports to a file: use a private temporary folder and delete it right away.
umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"$SPARKLE_BIN/generate_keys" --account "$SLUG" -x "$TMP/key" >/dev/null 2>&1 \
    || { echo "❌ No hay clave Sparkle '$SLUG' en el llavero" >&2; exit 1; }
[ -s "$TMP/key" ] || { echo "❌ La exportación de la clave '$SLUG' salió vacía" >&2; exit 1; }

KEY="$(tr -d '\n' < "$TMP/key")"
rm -rf "$TMP"
printf '%s' "$KEY" | pbcopy

echo "🔑 Clave privada de Sparkle '$SLUG' copiada al portapapeles."
echo "   Pégala en tu gestor de contraseñas (nombre sugerido: «Sparkle $SLUG»)."
echo "   El portapapeles se borrará en $SECONDS_TO_CLEAR s."

# Clears it later, but only if the user has not copied something else meanwhile.
(
    sleep "$SECONDS_TO_CLEAR"
    if [ "$(pbpaste)" = "$KEY" ]; then printf '' | pbcopy; fi
) >/dev/null 2>&1 &
disown
