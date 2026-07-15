#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Codex Quota Menu.app}"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/CodexQuotaMenu"
METHOD_FILE="$ROOT/Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift"
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

expect_plist CFBundleDevelopmentRegion zh_CN
expect_plist CFBundleDisplayName "Codex Quota Menu"
expect_plist CFBundleExecutable CodexQuotaMenu
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

test -f "$METHOD_FILE" || fail "missing AppServer method source"
METHOD_ENUM="$(/usr/bin/sed -n '/^enum AppServerMethod:/,/^}/p' "$METHOD_FILE")"
CASE_COUNT="$(printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Ec '^[[:space:]]+case ')"
test "$CASE_COUNT" = 3 || fail "AppServerMethod must contain exactly three cases"
printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Eq '^[[:space:]]+case initialize[[:space:]]*$' \
  || fail "initialize method is missing"
printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Eq '^[[:space:]]+case initialized[[:space:]]*$' \
  || fail "initialized method is missing"
printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Eq \
  '^[[:space:]]+case rateLimitsRead = "account/rateLimits/read"[[:space:]]*$' \
  || fail "account/rateLimits/read method is missing"

if printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Eiq '(consume|redeem|write)'; then
  fail "consume/redeem/write AppServer method found"
fi

SEND_CALL_COUNT="$(/usr/bin/grep -Ec '\.send[[:space:]]*\(' "$METHOD_FILE")"
test "$SEND_CALL_COUNT" = 3 || fail "client must contain exactly three send call sites"

SEND_BLOCKS="$(/usr/bin/awk '
  /\.send[[:space:]]*\(/ {
    if (inSend) exit 2
    inSend = 1
    count += 1
  }
  inSend { print }
  inSend && /^[[:space:]]*\)[[:space:]]*$/ { inSend = 0 }
  END {
    if (inSend || count != 3) exit 1
  }
' "$METHOD_FILE")" || fail "could not isolate the three send payloads"

for method in initialize initialized rateLimitsRead; do
  SOURCE_METHOD_COUNT="$(/usr/bin/grep -Ec "AppServerMethod\\.$method\\.rawValue" "$METHOD_FILE")"
  test "$SOURCE_METHOD_COUNT" = 1 \
    || fail "AppServerMethod.$method must appear exactly once in client source"
  SEND_METHOD_COUNT="$(printf '%s\n' "$SEND_BLOCKS" \
    | /usr/bin/grep -Ec "AppServerMethod\\.$method\\.rawValue")"
  test "$SEND_METHOD_COUNT" = 1 \
    || fail "AppServerMethod.$method must appear in exactly one send payload"
done

if printf '%s\n' "$SEND_BLOCKS" | /usr/bin/grep -Eiq '(consume|redeem|write)'; then
  fail "consume/redeem/write outbound send payload found"
fi

if /usr/bin/grep -REn '"method"[[:space:]]*:[[:space:]]*"[^\\]' "$ROOT/Sources"; then
  fail "literal outbound method string found outside the closed enum"
fi

if /usr/bin/grep -REni \
  '"method"[[:space:]]*:[[:space:]]*"[^"]*(consume|redeem|write)|account/[A-Za-z0-9_./-]*(consume|redeem|write)' \
  "$ROOT/Sources"; then
  fail "consume/redeem/write outbound method found"
fi

"$ROOT/scripts/test.sh" --filter CodexAppServerClientTests.testInitializesThenReadsRateLimitsUsingOnlyWhitelistedMethodsAndExactParameters

cd "$ROOT"
swift build -c release "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build -c release --show-bin-path "${SWIFT_ARGS[@]}")"
REFERENCE_APP="$SUPPORT_DIR/verification-reference/Codex Quota Menu.app"
rm -rf "$REFERENCE_APP"
mkdir -p "$REFERENCE_APP/Contents/MacOS" "$REFERENCE_APP/Contents/Resources"
cp "$BIN_DIR/CodexQuotaMenu" "$REFERENCE_APP/Contents/MacOS/CodexQuotaMenu"
cp "$ROOT/Resources/Info.plist" "$REFERENCE_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$REFERENCE_APP"
CURRENT_RELEASE_EXECUTABLE="$REFERENCE_APP/Contents/MacOS/CodexQuotaMenu"
/usr/bin/cmp -s "$CURRENT_RELEASE_EXECUTABLE" "$EXECUTABLE" \
  || fail "bundle executable does not match the current audited release build"
rm -rf "$REFERENCE_APP"

echo "Verified: $APP"
