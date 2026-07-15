#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SUPPORT_DIR="$ROOT/.build/codex-quota-menu-support/test"
SWIFTPM_DIR="$SUPPORT_DIR/swiftpm"
export CLANG_MODULE_CACHE_PATH="$SUPPORT_DIR/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$SUPPORT_DIR/swiftpm-module-cache"
INTERFACE_COMPILER_VERSION="${CODEX_QUOTA_INTERFACE_COMPILER_VERSION:-6.3.2}"

mkdir -p \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE" \
  "$SWIFTPM_DIR/cache" \
  "$SWIFTPM_DIR/config" \
  "$SWIFTPM_DIR/security" \
  "$SUPPORT_DIR/build"

SWIFT_ARGS=(
  --disable-sandbox
  --cache-path "$SWIFTPM_DIR/cache"
  --config-path "$SWIFTPM_DIR/config"
  --security-path "$SWIFTPM_DIR/security"
  --scratch-path "$SUPPORT_DIR/build"
  -Xswiftc -Xfrontend
  -Xswiftc -interface-compiler-version
  -Xswiftc -Xfrontend
  -Xswiftc "$INTERFACE_COMPILER_VERSION"
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xswiftc -warnings-as-errors
  -Xlinker -rpath
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
  -Xlinker -rpath
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
)

swift test "${SWIFT_ARGS[@]}" "$@"
