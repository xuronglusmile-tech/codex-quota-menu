#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Codex Quota Menu.app}"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/CodexQuotaMenu"
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
  --scratch-path "$ROOT/.build"
  -Xswiftc -Xfrontend
  -Xswiftc -interface-compiler-version
  -Xswiftc -Xfrontend
  -Xswiftc "$INTERFACE_COMPILER_VERSION"
  -Xswiftc -warnings-as-errors
)

fail() {
  echo "Verification failed: $*" >&2
  exit 1
}

expect_plist() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
  test "$actual" = "$expected" || fail "$key is '$actual'; expected '$expected'"
}

test -d "$APP" || fail "missing app bundle: $APP"
test -f "$PLIST" || fail "missing Info.plist"
/usr/bin/plutil -lint "$PLIST" >/dev/null
test -x "$EXECUTABLE" || fail "missing executable CodexQuotaMenu"
ICON="$APP/Contents/Resources/AppIcon.icns"
test -s "$ICON" || fail "missing app icon: $ICON"
/usr/bin/plutil -extract CFBundleIconFile raw -o - "$APP/Contents/Info.plist" \
  | /usr/bin/grep -Fx "AppIcon.icns" >/dev/null \
  || fail "Info.plist does not declare AppIcon.icns"

expect_plist CFBundleDevelopmentRegion zh_CN
expect_plist CFBundleDisplayName "Codex Quota Menu"
expect_plist CFBundleExecutable CodexQuotaMenu
expect_plist CFBundleIconFile AppIcon.icns
expect_plist CFBundleIdentifier local.scott.CodexQuotaMenu
expect_plist CFBundleInfoDictionaryVersion 6.0
expect_plist CFBundleName "Codex Quota Menu"
expect_plist CFBundlePackageType APPL
expect_plist CFBundleShortVersionString 0.1.0
expect_plist CFBundleVersion 1
expect_plist LSMinimumSystemVersion 14.0
expect_plist LSUIElement true
expect_plist NSHighResolutionCapable true

/usr/bin/codesign --verify --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)"
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Signature=adhoc$' \
  || fail "bundle is not ad-hoc signed"

"$ROOT/scripts/audit-outbound-methods.sh" "$ROOT/Sources"

"$ROOT/scripts/test.sh" --filter CodexAppServerClientTests.testInitializesThenReadsAccountSnapshotUsingOnlyWhitelistedMethods

cd "$ROOT"
swift build -c release "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${SWIFT_ARGS[@]}")"
REFERENCE_APP="$SUPPORT_DIR/verification-reference/Codex Quota Menu.app"
REFERENCE_ICON="$SUPPORT_DIR/verification-reference/AppIcon.icns"
rm -rf "$REFERENCE_APP"
mkdir -p "$REFERENCE_APP/Contents/MacOS" "$REFERENCE_APP/Contents/Resources"
"$ROOT/scripts/build-app-icon.sh" "$REFERENCE_ICON"
cp "$BIN_DIR/CodexQuotaMenu" "$REFERENCE_APP/Contents/MacOS/CodexQuotaMenu"
cp "$ROOT/Resources/Info.plist" "$REFERENCE_APP/Contents/Info.plist"
cp "$REFERENCE_ICON" "$REFERENCE_APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$REFERENCE_APP"
CURRENT_RELEASE_EXECUTABLE="$REFERENCE_APP/Contents/MacOS/CodexQuotaMenu"
/usr/bin/cmp -s "$CURRENT_RELEASE_EXECUTABLE" "$EXECUTABLE" \
  || fail "bundle executable does not match the current audited release build"
rm -rf "$REFERENCE_APP"

echo "Verified: $APP"
