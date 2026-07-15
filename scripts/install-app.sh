#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/dist/Codex Quota Menu.app"
TARGET="/Applications/Codex Quota Menu.app"

test -d "$SOURCE"
"$ROOT/scripts/verify-app.sh" "$SOURCE"

STAGING_ROOT="$(mktemp -d "/Applications/.codex-quota-menu-install.XXXXXX")"
STAGED="$STAGING_ROOT/Codex Quota Menu.app"
BACKUP="$STAGING_ROOT/previous-Codex Quota Menu.app"
NEW_TARGET_INSTALLED=0
COMMITTED=0

cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if test "$COMMITTED" -eq 0 && test -e "$BACKUP"; then
    rm -rf "$TARGET"
    /bin/mv "$BACKUP" "$TARGET"
  elif test "$COMMITTED" -eq 0 && test "$NEW_TARGET_INSTALLED" -eq 1; then
    rm -rf "$TARGET"
  fi

  rm -rf "$STAGING_ROOT"
  exit "$status"
}
trap cleanup EXIT

/usr/bin/ditto "$SOURCE" "$STAGED"
"$ROOT/scripts/verify-app.sh" "$STAGED"

if test -e "$TARGET"; then
  /bin/mv "$TARGET" "$BACKUP"
fi
/bin/mv "$STAGED" "$TARGET"
NEW_TARGET_INSTALLED=1

"$ROOT/scripts/verify-app.sh" "$TARGET"
/usr/bin/open "$TARGET"
COMMITTED=1

echo "$TARGET"
