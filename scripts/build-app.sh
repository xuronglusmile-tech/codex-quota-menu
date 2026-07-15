#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SUPPORT_DIR="$ROOT/.build/codex-quota-menu-support"
SWIFTPM_DIR="$SUPPORT_DIR/swiftpm"
export CLANG_MODULE_CACHE_PATH="$SUPPORT_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SUPPORT_DIR/swiftpm-module-cache"
INTERFACE_COMPILER_VERSION="${CODEX_QUOTA_INTERFACE_COMPILER_VERSION:-6.3.2}"

mkdir -p \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE" \
  "$SWIFTPM_DIR/cache" \
  "$SWIFTPM_DIR/config" \
  "$SWIFTPM_DIR/security"

SWIFT_ARGS=(
  --disable-sandbox
  --cache-path "$SWIFTPM_DIR/cache"
  --config-path "$SWIFTPM_DIR/config"
  --security-path "$SWIFTPM_DIR/security"
  -Xswiftc -Xfrontend
  -Xswiftc -interface-compiler-version
  -Xswiftc -Xfrontend
  -Xswiftc "$INTERFACE_COMPILER_VERSION"
  -Xswiftc -warnings-as-errors
)

swift build -c release "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${SWIFT_ARGS[@]}")"

APP="$ROOT/dist/Codex Quota Menu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexQuotaMenu" "$APP/Contents/MacOS/CodexQuotaMenu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"

echo "$APP"
