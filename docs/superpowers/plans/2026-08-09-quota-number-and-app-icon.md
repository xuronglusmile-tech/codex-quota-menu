# Quota Number and App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make quota percentages in the popover explicitly white and package a reproducible macOS app icon for Codex Quota Menu without changing quota behavior.

**Architecture:** Keep the SwiftUI popover and existing dynamic menu-bar quota pill unchanged except for an explicit white style on the percentage value. Add a vector SVG source and a macOS-native `sips`/`iconutil` generator that builds `AppIcon.icns` into the app bundle during `build-app.sh`, with Info.plist and packaging-contract checks covering the integration.

**Tech Stack:** Swift 6.3 / SwiftPM, SwiftUI, AppKit, macOS `sips`, macOS `iconutil`, shell build scripts, Swift Testing.

## Global Constraints

- Requires macOS 14 or later and Apple Command Line Tools.
- The app remains read-only and may call only the existing `initialize`, `initialized`, `account/rateLimits/read`, and `account/usage/read` app-server methods.
- Keep the existing 20%/10% menu-bar pill color thresholds and live percentage text unchanged.
- Do not add third-party runtime dependencies.
- Do not pre-render macOS rounded-corner masking into the icon source.
- The app bundle must remain an `LSUIElement` menu-bar-only application.

---

### Task 1: Lock the requested behavior with failing packaging tests

**Files:**
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`
- Test: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`

**Interfaces:**
- Consumes: existing source-contract tests and the current `Resources/Info.plist` / `scripts/build-app.sh` contents.
- Produces: failing assertions that define the required white text, icon plist key, icon build script, and app-bundle copy step.

- [ ] **Step 1: Add the failing assertions**

Extend `testMenuRendersIndependentMonthlyValueSectionWithoutRemovingControls` after the existing quota assertions:

```swift
#expect(menuSource.contains("Text(\"\\(window.remainingPercent)%\")"))
#expect(menuSource.contains(".foregroundStyle(.white)"))
```

Add a new test:

```swift
@Test
func testAppIconIsDeclaredAndCopiedIntoTheBundle() throws {
    let plistSource = try String(
        contentsOf: root.appendingPathComponent("Resources/Info.plist"),
        encoding: .utf8
    )
    let buildScript = try String(
        contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
        encoding: .utf8
    )
    let iconScriptURL = root.appendingPathComponent("scripts/build-app-icon.sh")

    #expect(plistSource.contains("CFBundleIconFile"))
    #expect(plistSource.contains("AppIcon.icns"))
    #expect(buildScript.contains("build-app-icon.sh"))
    #expect(buildScript.contains("Contents/Resources/AppIcon.icns"))
    #expect(FileManager.default.fileExists(atPath: iconScriptURL.path))
    #expect(try executablePermissions(of: iconScriptURL) == 0o755)
}
```

Update the existing exact Info.plist key-set assertion to include `CFBundleIconFile`, and update the verification-script key loop to require the same key.

- [ ] **Step 2: Run the focused test and verify it fails for the missing behavior**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests
```

Expected: FAIL because the percentage has no explicit `.foregroundStyle(.white)`, the icon key/script/copy step do not yet exist, and the exact plist key set does not include `CFBundleIconFile`.

- [ ] **Step 3: Commit the red test**

```bash
git add Tests/CodexQuotaMenuTests/PackagingContractTests.swift
git commit -m "test: specify white quota text and app icon contract"
```

### Task 2: Implement white quota text and reproducible icon generation

**Files:**
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift:72-81`
- Modify: `Resources/Info.plist`
- Create: `Resources/AppIcon.svg`
- Create: `scripts/build-app-icon.sh`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: Task 1's source-contract expectations.
- Produces: a white quota percentage and a generated `AppIcon.icns` file that the app bundle can load.

- [ ] **Step 1: Add the minimal production changes**

Change only the quota percentage value in `MenuBarContentView.quotaContent`:

```swift
Text("\\(window.remainingPercent)%")
    .bold()
    .foregroundStyle(.white)
```

Add this key/value to `Resources/Info.plist`:

```xml
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
```

Add `Resources/AppIcon.svg` as a square vector source with a dark navy rounded-square field. It must depict one blue horizontal quota pill with a visible white/blue fill split and a centered white lightning mark; it must contain no text, percentage, account data, or pre-rendered outer macOS corner mask.

Add executable `scripts/build-app-icon.sh` with this interface:

```bash
./scripts/build-app-icon.sh <output-icns-path>
```

The script must:

1. Resolve the repository root from its own directory.
2. Require exactly one output path and create its parent directory.
3. Create a temporary `.iconset` under `.build` with a cleanup trap.
4. Rasterize `Resources/AppIcon.svg` with `/usr/bin/sips` into the standard iconset sizes: `icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`, `icon_32x32@2x.png`, `icon_128x128.png`, `icon_128x128@2x.png`, `icon_256x256.png`, `icon_256x256@2x.png`, `icon_512x512.png`, and `icon_512x512@2x.png` (the `@2x` files use 32, 64, 256, 512, and 1024 pixel raster sizes respectively).
5. Run `/usr/bin/iconutil --convert icns --output <output> <iconset>`.

Update `scripts/build-app.sh` after the app directories are created:

```bash
ICON="$ROOT/.build/generated/AppIcon.icns"
"$ROOT/scripts/build-app-icon.sh" "$ICON"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
```

The existing executable, plist copy, and ad-hoc bundle signing remain in their current order; copy the icon before signing.

- [ ] **Step 2: Run the focused test and verify it passes**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests
```

Expected: PASS, including the new white-style and app-icon contract tests.

- [ ] **Step 3: Commit the implementation**

```bash
git add Sources/CodexQuotaMenu/UI/MenuBarContentView.swift \
  Resources/Info.plist Resources/AppIcon.svg \
  scripts/build-app-icon.sh scripts/build-app.sh \
  Tests/CodexQuotaMenuTests/PackagingContractTests.swift
git commit -m "feat: add white quota text and app icon"
```

### Task 3: Extend bundle verification and run the complete validation suite

**Files:**
- Modify: `scripts/verify-app.sh`
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 2's generated `dist/Codex Quota Menu.app/Contents/Resources/AppIcon.icns`.
- Produces: verification that the final signed bundle contains the declared icon and documentation for the new build step.

- [ ] **Step 1: Add icon checks to `verify-app.sh`**

After the existing Info.plist checks, add:

```bash
ICON="$APP/Contents/Resources/AppIcon.icns"
test -s "$ICON"
plutil -extract CFBundleIconFile raw -o - "$APP/Contents/Info.plist" | grep -Fx 'AppIcon.icns'
```

Keep the current signature, executable, byte-comparison, and outbound-method checks unchanged.

- [ ] **Step 2: Document the icon build behavior**

Add to `README.md` under Build and test that `build-app.sh` rasterizes `Resources/AppIcon.svg` into `AppIcon.icns`, copies it into the app bundle, and does not commit `.build` or `dist` outputs.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
./scripts/test.sh
```

Expected: exit code 0 and all tests pass.

- [ ] **Step 4: Build and verify the app bundle**

Run:

```bash
./scripts/build-app.sh
./scripts/verify-app.sh
./scripts/audit-outbound-methods.sh Sources
```

Expected: the bundle contains a non-empty `Contents/Resources/AppIcon.icns`, its Info.plist declares `AppIcon.icns`, code-signature verification passes, the current release executable matches the reference build, and the outbound audit reports no disallowed methods.

- [ ] **Step 5: Inspect the final diff and commit verification/docs**

Run:

```bash
git status --short
git diff --check
git diff HEAD~1 --stat
```

Then commit only the verification/documentation files:

```bash
git add scripts/verify-app.sh README.md Tests/CodexQuotaMenuTests/PackagingContractTests.swift
git commit -m "test: verify packaged app icon"
```
