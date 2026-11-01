#!/bin/bash
# Downloads the official Sparkle tools (sign_update, generate_keys…) into tools/sparkle (not committed).
set -euo pipefail
SPARKLE_VERSION="2.10.1"
DIR="$(cd "$(dirname "$0")" && pwd)/sparkle"

if [ -x "$DIR/bin/sign_update" ] && [ "$(cat "$DIR/.version" 2>/dev/null)" = "$SPARKLE_VERSION" ]; then
    echo "Sparkle $SPARKLE_VERSION ya está en $DIR"
    exit 0
fi
rm -rf "$DIR" && mkdir -p "$DIR"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$DIR/sparkle.tar.xz"
tar -xJf "$DIR/sparkle.tar.xz" -C "$DIR"
rm "$DIR/sparkle.tar.xz"
# The tools are signed by the Sparkle project; refuse anything that doesn't verify.
for tool in sign_update generate_keys; do
    codesign --verify --strict "$DIR/bin/$tool"
done
echo "$SPARKLE_VERSION" > "$DIR/.version"
echo "Sparkle $SPARKLE_VERSION instalado en $DIR"
