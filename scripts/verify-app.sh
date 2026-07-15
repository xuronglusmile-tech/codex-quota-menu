#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Codex Quota Menu.app}"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/CodexQuotaMenu"
METHOD_FILE="$ROOT/Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift"

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

METHOD_SEND_COUNT="$(/usr/bin/grep -Ec \
  'AppServerMethod\.(initialize|initialized|rateLimitsRead)\.rawValue' \
  "$METHOD_FILE")"
test "$METHOD_SEND_COUNT" = 3 \
  || fail "outbound calls must use each closed AppServerMethod exactly once"

if /usr/bin/grep -REn '"method"[[:space:]]*:[[:space:]]*"[^\\]' "$ROOT/Sources"; then
  fail "literal outbound method string found outside the closed enum"
fi

if /usr/bin/grep -REni \
  '"method"[[:space:]]*:[[:space:]]*"[^"]*(consume|redeem|write)|account/[A-Za-z0-9_./-]*(consume|redeem|write)' \
  "$ROOT/Sources"; then
  fail "consume/redeem/write outbound method found"
fi

echo "Verified: $APP"
