#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="${1:-$ROOT/Sources}"
ALLOWED_CLIENT_RELATIVE="CodexQuotaMenu/Services/CodexAppServerClient.swift"

fail() {
  echo "Outbound method audit failed: $*" >&2
  exit 1
}

count_send_calls() {
  local source_file="$1"
  {
    /usr/bin/grep -Eo '\.[[:space:]]*send[[:space:]]*\(' "$source_file" || true
  } | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]'
}

count_send_references() {
  local source_file="$1"
  {
    /usr/bin/grep -Eo '\.[[:space:]]*send([^[:alnum:]_]|$)' "$source_file" || true
  } | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]'
}

test "$#" -le 1 || fail "expected at most one source root"
test -d "$SOURCE_ROOT" || fail "missing source root: $SOURCE_ROOT"
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd)"
ALLOWED_CLIENT="$SOURCE_ROOT/$ALLOWED_CLIENT_RELATIVE"
test -f "$ALLOWED_CLIENT" || fail "missing allowed client: $ALLOWED_CLIENT"

SWIFT_FILES=()
while IFS= read -r -d '' source_file; do
  SWIFT_FILES+=("$source_file")
done < <(/usr/bin/find "$SOURCE_ROOT" -type f -name '*.swift' -print0)
test "${#SWIFT_FILES[@]}" -gt 0 || fail "no Swift sources found"

GLOBAL_SEND_REFERENCE_COUNT=0
for source_file in "${SWIFT_FILES[@]}"; do
  FILE_SEND_REFERENCE_COUNT="$(count_send_references "$source_file")"
  GLOBAL_SEND_REFERENCE_COUNT=$((GLOBAL_SEND_REFERENCE_COUNT + FILE_SEND_REFERENCE_COUNT))
  if test "$source_file" != "$ALLOWED_CLIENT" && test "$FILE_SEND_REFERENCE_COUNT" -ne 0; then
    FILE_SEND_CALL_COUNT="$(count_send_calls "$source_file")"
    if test "$FILE_SEND_CALL_COUNT" -ne 0; then
      fail "send call outside allowed client: $source_file"
    fi
    fail "send reference outside allowed client: $source_file"
  fi
done
test "$GLOBAL_SEND_REFERENCE_COUNT" -eq 3 \
  || fail "Sources must contain exactly three send references; found $GLOBAL_SEND_REFERENCE_COUNT"

METHOD_ENUM="$(/usr/bin/sed -n '/^enum AppServerMethod:/,/^}/p' "$ALLOWED_CLIENT")"
CASE_COUNT="$(printf '%s\n' "$METHOD_ENUM" | /usr/bin/grep -Ec '^[[:space:]]+case ' || true)"
test "$CASE_COUNT" -eq 3 || fail "AppServerMethod must contain exactly three cases"
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

SEND_BLOCKS="$(/usr/bin/awk '
  /\.[[:space:]]*send[[:space:]]*\(/ {
    if (inSend) exit 2
    inSend = 1
    count += 1
  }
  inSend { print }
  inSend && /^[[:space:]]*\)[[:space:]]*$/ { inSend = 0 }
  END {
    if (inSend || count != 3) exit 1
  }
' "$ALLOWED_CLIENT")" || fail "could not isolate the three send payloads"

NORMALIZED_SEND_LINES="$(printf '%s\n' "$SEND_BLOCKS" \
  | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
NONEMPTY_SEND_LINE_COUNT="$(printf '%s\n' "$NORMALIZED_SEND_LINES" \
  | /usr/bin/grep -Ec '.' || true)"
SEND_OPENER_COUNT="$(printf '%s\n' "$NORMALIZED_SEND_LINES" \
  | /usr/bin/grep -Ec '^try await [A-Za-z_][A-Za-z0-9_]*\.send\($' || true)"
SEND_CLOSER_COUNT="$(printf '%s\n' "$NORMALIZED_SEND_LINES" \
  | /usr/bin/grep -Ec '^\)$' || true)"
test "$NONEMPTY_SEND_LINE_COUNT" -eq 9 \
  || fail "send calls must contain only the three exact payloads"
test "$SEND_OPENER_COUNT" -eq 3 \
  || fail "send calls must use the exact audited call shape"
test "$SEND_CLOSER_COUNT" -eq 3 \
  || fail "send calls must use the exact audited call shape"

EXPECTED_RATE_LIMITS='#"{"method":"\#(AppServerMethod.rateLimitsRead.rawValue)","id":1,"params":null}"#'
EXPECTED_INITIALIZE='#"{"method":"\#(AppServerMethod.initialize.rawValue)","id":0,"params":{"clientInfo":{"name":"codex_quota_menu","title":"Codex Quota Menu","version":"0.1.0"}}}"#'
EXPECTED_INITIALIZED='#"{"method":"\#(AppServerMethod.initialized.rawValue)","params":{}}"#'

for expected_payload in \
  "$EXPECTED_RATE_LIMITS" \
  "$EXPECTED_INITIALIZE" \
  "$EXPECTED_INITIALIZED"; do
  PAYLOAD_COUNT="$(printf '%s\n' "$NORMALIZED_SEND_LINES" \
    | /usr/bin/grep -Fxc "$expected_payload" || true)"
  test "$PAYLOAD_COUNT" -eq 1 \
    || fail "each allowed outbound payload must appear exactly once"
done

METHOD_KEY_COUNT="$(printf '%s\n' "$NORMALIZED_SEND_LINES" \
  | /usr/bin/grep -Foc '"method"' || true)"
test "$METHOD_KEY_COUNT" -eq 3 \
  || fail "dynamic or additional outbound method found"

if /usr/bin/grep -REni \
  '"method"[[:space:]]*:[[:space:]]*"[^"]*(consume|redeem|write)|account/[A-Za-z0-9_./-]*(consume|redeem|write)' \
  "$SOURCE_ROOT"; then
  fail "consume/redeem/write outbound method found"
fi

echo "Audited outbound methods: $SOURCE_ROOT"
