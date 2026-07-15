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

## Privacy

The app does not read browser cookies, ChatGPT credentials, Codex authentication files, or the Codex state database. It stores only the latest display snapshot and SHA-256 notification identifiers under `~/Library/Application Support/Codex Quota Menu`.

## Uninstall

Quit the menu app, disable “登录时启动”, move `/Applications/Codex Quota Menu.app` to Trash, and remove `~/Library/Application Support/Codex Quota Menu` if the cached display data is no longer wanted.
