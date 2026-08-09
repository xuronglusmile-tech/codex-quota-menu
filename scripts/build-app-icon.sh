#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output-icns-path>" >&2
  exit 2
fi

OUTPUT="$1"
SOURCE="$ROOT/Resources/AppIcon.svg"
WORK_DIR=""

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

test -f "$SOURCE"
mkdir -p "$(dirname "$OUTPUT")" "$ROOT/.build"
WORK_DIR="$(mktemp -d "$ROOT/.build/codex-quota-icon.XXXXXX")"
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

rasterize() {
  local size="$1"
  local filename="$2"
  /usr/bin/sips \
    -s format png \
    -z "$size" "$size" \
    "$SOURCE" \
    --out "$ICONSET/$filename" >/dev/null
}

rasterize 16 icon_16x16.png
rasterize 32 icon_16x16@2x.png
rasterize 32 icon_32x32.png
rasterize 64 icon_32x32@2x.png
rasterize 128 icon_128x128.png
rasterize 256 icon_128x128@2x.png
rasterize 256 icon_256x256.png
rasterize 512 icon_256x256@2x.png
rasterize 512 icon_512x512.png
rasterize 1024 icon_512x512@2x.png

/usr/bin/iconutil --convert icns --output "$OUTPUT" "$ICONSET"
test -s "$OUTPUT"
