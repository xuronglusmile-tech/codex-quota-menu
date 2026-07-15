# Codex Quota Menu

Native read-only macOS menu-bar display for Codex quota windows and reset-credit expiration times.

## Build and test

Requires macOS 14 or later and the Apple Command Line Tools.

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh
```

The test and build scripts keep their SwiftPM and module caches under the project `.build` directory. They default to SDK interface compiler compatibility version `6.3.2`; set `CODEX_QUOTA_INTERFACE_COMPILER_VERSION` only when the installed SDK requires another version. The verification script runs the focused fake-client whitelist test, rebuilds the current release executable, and byte-compares it with the signed bundle executable.

The real-account smoke test is opt-in and must be run only with approval:

```bash
RUN_LIVE_CODEX_TESTS=1 ./scripts/test.sh --filter LiveCodexSmokeTests
```

## Install

```bash
./scripts/install-app.sh
```

Quit Codex Quota Menu before installing or updating. The installer refuses to replace a running copy and tells you to quit and retry.

The app uses the Codex executable bundled in `/Applications/ChatGPT.app`, reuses its existing login, refreshes every five minutes, and never redeems a reset credit. The installer needs write access to `/Applications`, verifies a staged copy before replacement, atomically swaps it with an existing installation, verifies the installed copy, and then opens a new instance without `sudo`. If post-swap verification or launch fails, it atomically restores the previous app; if rollback itself fails, it preserves and reports the exact recovery directory.

The app also reads `account/usage/read` every five minutes and sums only the
current calendar month's date-only usage buckets. It converts total tokens into
a GPT-5.6 Sol API-equivalent range using fixed `$2.65 / 1M` and `$8.20 / 1M`
scenarios. This is an estimate, not an OpenAI bill or a valuation of all Plus or
Pro subscription features.

## Privacy

The app does not read browser cookies, ChatGPT credentials, Codex authentication files, the Codex state database, conversation logs, or session logs. It stores only the latest display snapshot under `~/Library/Application Support/Codex Quota Menu`; monthly usage cache data is limited to the derived monthly token total, month start, and fetch time. SHA-256 notification identifiers and preference flags are stored in the app's standard UserDefaults domain, `local.scott.CodexQuotaMenu`.

## Uninstall

First disable “到期通知” so the app removes its pending owned notification requests. Then disable “登录时启动”. Quit the menu app, move `/Applications/Codex Quota Menu.app` to Trash, and remove `~/Library/Application Support/Codex Quota Menu` if the cached display data is no longer wanted. Finally remove the notification hashes and preference flags from the defaults domain:

```bash
defaults delete local.scott.CodexQuotaMenu
```
