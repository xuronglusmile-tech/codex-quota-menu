# Codex Quota Menu

Native read-only macOS menu-bar display for Codex quota windows and reset-credit expiration times.

## Build and test

Requires macOS 14 or later and the Apple Command Line Tools.

```bash
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
```

The build script keeps its SwiftPM and module caches under the project `.build` directory. It defaults to SDK interface compiler compatibility version `6.3.2`; set `CODEX_QUOTA_INTERFACE_COMPILER_VERSION` only when the installed SDK requires another version.

## Install

```bash
./scripts/install-app.sh
```

The app uses the Codex executable bundled in `/Applications/ChatGPT.app`, reuses its existing login, refreshes every five minutes, and never redeems a reset credit. The installer needs write access to `/Applications`, verifies a staged copy before replacing an existing installation, verifies the installed copy, and then opens it without `sudo`.

## Privacy

The app does not read browser cookies, ChatGPT credentials, Codex authentication files, or the Codex state database. It stores only the latest display snapshot and SHA-256 notification identifiers under `~/Library/Application Support/Codex Quota Menu`.

## Uninstall

Quit the menu app, disable “登录时启动”, move `/Applications/Codex Quota Menu.app` to Trash, and remove `~/Library/Application Support/Codex Quota Menu` if the cached display data is no longer wanted.
