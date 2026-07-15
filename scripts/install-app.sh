#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/dist/Codex Quota Menu.app"
TARGET="/Applications/Codex Quota Menu.app"

ensure_not_running() {
  if /usr/bin/pgrep -x CodexQuotaMenu >/dev/null; then
    echo "Codex Quota Menu is running. Quit Codex Quota Menu and retry the install." >&2
    exit 1
  fi
}

ensure_not_running
test -d "$SOURCE"
"$ROOT/scripts/verify-app.sh" "$SOURCE"

STAGING_ROOT="$(mktemp -d "/Applications/.codex-quota-menu-install.XXXXXX")"
STAGED="$STAGING_ROOT/Codex Quota Menu.app"
SWAP_HELPER="$STAGING_ROOT/atomic-swap"
STATE="staging"
PRESERVE_STAGING=0

cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if test "$status" -ne 0; then
    case "$STATE" in
      swapped)
        if "$SWAP_HELPER" "$STAGED" "$TARGET"; then
          STATE="rolled-back"
        else
          PRESERVE_STAGING=1
          echo "Rollback failed; preserving recovery directory: $STAGING_ROOT" >&2
          echo "Previous app bundle remains at: $STAGED" >&2
          echo "Installed candidate remains at: $TARGET" >&2
        fi
        ;;
      installed-new)
        if /bin/mv "$TARGET" "$STAGED"; then
          STATE="rolled-back"
        else
          PRESERVE_STAGING=1
          echo "Rollback failed; preserving recovery directory: $STAGING_ROOT" >&2
          echo "Installed candidate remains at: $TARGET" >&2
        fi
        ;;
    esac
  fi

  if test "$PRESERVE_STAGING" -eq 0; then
    rm -rf "$STAGING_ROOT"
  else
    echo "Recovery directory preserved at: $STAGING_ROOT" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

/usr/bin/xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
  "$ROOT/scripts/atomic-swap.c" -o "$SWAP_HELPER"
/usr/bin/ditto "$SOURCE" "$STAGED"
"$ROOT/scripts/verify-app.sh" "$STAGED"
ensure_not_running

if test -e "$TARGET" || test -L "$TARGET"; then
  "$SWAP_HELPER" "$STAGED" "$TARGET"
  STATE="swapped"
else
  /bin/mv "$STAGED" "$TARGET"
  STATE="installed-new"
fi

"$ROOT/scripts/verify-app.sh" "$TARGET"
/usr/bin/open -n "$TARGET"
echo "$TARGET"
STATE="committed"
