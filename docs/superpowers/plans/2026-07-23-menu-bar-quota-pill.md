# Menu Bar Quota Pill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu-bar gauge and reset-count title with a weekly quota percentage followed by a battery-style pill whose fill and color show the same remaining quota.

**Architecture:** Convert `MenuBarPresentation` into a pure value model that selects the weekly window and derives text, fill fraction, status band, and accessibility copy from `QuotaDisplayState`. Render that model in a focused SwiftUI label view and wire it into `MenuBarExtra`; transport, caching, monthly usage, notifications, and popover content remain unchanged.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, Swift Testing, Swift Package Manager, macOS 14+

## Global Constraints

- The percentage appears to the left of the pill: `31%  [pill]`.
- The percentage is never drawn inside or over the pill.
- The pill uses only the weekly window whose `durationMinutes == 10_080`.
- Weekly remaining `20%...100%` is green, `10%...19%` is yellow, and `0%...9%` is red.
- Reset-credit count remains in the popover and is removed from the menu-bar label.
- Loading shows `--`; stale data adds `!`; unavailable data shows `不可用`.
- Do not change account reads, refresh timing, caching, notifications, reset credits, monthly estimates, or popover progress bars.
- Do not add dependencies or persistent data.
- Continue development directly on `main`; do not create a worktree or feature branch.

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift` | Pure mapping from quota state to menu-bar text, fill, band, and accessibility label |
| `Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift` | SwiftUI percentage-first pill rendering |
| `Sources/CodexQuotaMenu/UI/QuotaStore.swift` | Exposes the derived menu-bar presentation to the app scene |
| `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift` | Uses the new custom label in `MenuBarExtra` |
| `Tests/CodexQuotaMenuTests/MenuBarPresentationTests.swift` | Boundary, window-selection, clamping, and state tests for the presentation model |
| `Tests/CodexQuotaMenuTests/QuotaModelsTests.swift` | Removes the superseded compound-title test |
| `Tests/CodexQuotaMenuTests/PackagingContractTests.swift` | Verifies percentage-before-pill wiring, colors, and removal of the gauge symbol |
| `README.md` | Documents the always-visible weekly quota indicator |

---

### Task 1: Weekly Menu-Bar Presentation Model

**Files:**
- Create: `Tests/CodexQuotaMenuTests/MenuBarPresentationTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/QuotaModelsTests.swift`
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift`
- Modify: `Sources/CodexQuotaMenu/UI/QuotaStore.swift`

**Interfaces:**
- Consumes: `QuotaDisplayState`, `QuotaSnapshot`, `QuotaWindow.remainingPercent`, `QuotaProgressPresentation.band(remainingPercent:durationMinutes:)`, and `QuotaProgressBand`.
- Produces: `MenuBarPresentation.make(for:) -> MenuBarPresentation` with `text: String`, `fillFraction: Double`, `band: QuotaProgressBand?`, and `accessibilityLabel: String`.

- [ ] **Step 1: Write focused failing presentation tests**

Create `Tests/CodexQuotaMenuTests/MenuBarPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct MenuBarPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_784_038_400)

    @Test
    func testUsesWeeklyWindowInsteadOfMoreConstrainedShortWindow() {
        let presentation = MenuBarPresentation.make(for: .fresh(snapshot(windows: [
            QuotaWindow(
                id: "short",
                label: "5 小时额度",
                usedPercent: 95,
                durationMinutes: 300,
                resetsAt: nil
            ),
            QuotaWindow(
                id: "weekly",
                label: "每周额度",
                usedPercent: 69,
                durationMinutes: 10_080,
                resetsAt: nil
            )
        ])))

        #expect(presentation.text == "31%")
        #expect(presentation.fillFraction == 0.31)
        #expect(presentation.band == .normal)
        #expect(presentation.accessibilityLabel == "每周剩余额度 31%")
    }

    @Test(arguments: [
        (20, QuotaProgressBand.normal),
        (19, QuotaProgressBand.warning),
        (10, QuotaProgressBand.warning),
        (9, QuotaProgressBand.critical)
    ])
    func testWeeklyColorBoundaries(
        remainingPercent: Int,
        expectedBand: QuotaProgressBand
    ) {
        let window = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 100 - remainingPercent,
            durationMinutes: 10_080,
            resetsAt: nil
        )

        #expect(
            MenuBarPresentation.make(for: .fresh(snapshot(windows: [window]))).band
                == expectedBand
        )
    }

    @Test
    func testClampsPercentageAndFillFraction() {
        let above = QuotaWindow(
            id: "above",
            label: "每周额度",
            usedPercent: -10,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let below = QuotaWindow(
            id: "below",
            label: "每周额度",
            usedPercent: 150,
            durationMinutes: 10_080,
            resetsAt: nil
        )

        let full = MenuBarPresentation.make(for: .fresh(snapshot(windows: [above])))
        let empty = MenuBarPresentation.make(for: .fresh(snapshot(windows: [below])))

        #expect(full.text == "100%")
        #expect(full.fillFraction == 1)
        #expect(full.band == .normal)
        #expect(empty.text == "0%")
        #expect(empty.fillFraction == 0)
        #expect(empty.band == .critical)
    }

    @Test
    func testLoadingMissingWeeklyStaleAndUnavailableStates() {
        let weekly = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 69,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let loading = MenuBarPresentation.make(for: .loading)
        let missing = MenuBarPresentation.make(for: .fresh(snapshot(windows: [])))
        let stale = MenuBarPresentation.make(
            for: .stale(snapshot(windows: [weekly]), message: "offline")
        )
        let unavailable = MenuBarPresentation.make(
            for: .unavailable(message: "missing")
        )

        #expect(loading.text == "--")
        #expect(loading.fillFraction == 0)
        #expect(loading.band == nil)
        #expect(loading.accessibilityLabel == "每周剩余额度载入中")
        #expect(missing.text == "--")
        #expect(missing.fillFraction == 0)
        #expect(missing.band == nil)
        #expect(missing.accessibilityLabel == "每周剩余额度不可用")
        #expect(stale.text == "31% !")
        #expect(stale.fillFraction == 0.31)
        #expect(stale.band == .normal)
        #expect(stale.accessibilityLabel == "每周剩余额度 31%，数据可能已过期")
        #expect(unavailable.text == "不可用")
        #expect(unavailable.fillFraction == 0)
        #expect(unavailable.band == nil)
        #expect(unavailable.accessibilityLabel == "每周剩余额度不可用")
    }

    @Test
    func testMenuBarTextDoesNotIncludeResetCreditCount() {
        let weekly = QuotaWindow(
            id: "weekly",
            label: "每周额度",
            usedPercent: 69,
            durationMinutes: 10_080,
            resetsAt: nil
        )
        let value = MenuBarPresentation.make(for: .fresh(snapshot(
            windows: [weekly],
            availableResetCount: 5
        )))

        #expect(value.text == "31%")
        #expect(!value.text.contains("·"))
    }

    private func snapshot(
        windows: [QuotaWindow],
        availableResetCount: Int = 0
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            windows: windows,
            availableResetCount: availableResetCount,
            resetCredits: [],
            fetchedAt: now
        )
    }
}
```

Delete `testMenuTitleCoversFreshStaleAndUnavailableStates()` from
`Tests/CodexQuotaMenuTests/QuotaModelsTests.swift`; the new file owns all
menu-bar presentation behavior.

- [ ] **Step 2: Run the focused tests and verify they fail for the missing model**

Run:

```bash
./scripts/test.sh --filter MenuBarPresentationTests
```

Expected: FAIL because the current enum has no `make(for:)`, stored
presentation properties, or equatable presentation value.

- [ ] **Step 3: Replace the title formatter with the pure presentation value**

Replace `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift` with:

```swift
struct MenuBarPresentation: Equatable, Sendable {
    let text: String
    let fillFraction: Double
    let band: QuotaProgressBand?
    let accessibilityLabel: String

    private static let weeklyDurationMinutes = 10_080

    static func make(for state: QuotaDisplayState) -> MenuBarPresentation {
        switch state {
        case .loading:
            return unavailable(
                text: "--",
                accessibilityLabel: "每周剩余额度载入中"
            )
        case .unavailable:
            return unavailable(
                text: "不可用",
                accessibilityLabel: "每周剩余额度不可用"
            )
        case .fresh(let snapshot):
            return make(snapshot: snapshot, isStale: false)
        case .stale(let snapshot, _):
            return make(snapshot: snapshot, isStale: true)
        }
    }

    private static func make(
        snapshot: QuotaSnapshot,
        isStale: Bool
    ) -> MenuBarPresentation {
        guard let weekly = snapshot.windows.first(where: {
            $0.durationMinutes == weeklyDurationMinutes
        }) else {
            return unavailable(
                text: "--",
                accessibilityLabel: "每周剩余额度不可用"
            )
        }

        let remaining = weekly.remainingPercent
        let suffix = isStale ? " !" : ""
        let accessibilitySuffix = isStale ? "，数据可能已过期" : ""

        return MenuBarPresentation(
            text: "\(remaining)%\(suffix)",
            fillFraction: Double(remaining) / 100,
            band: QuotaProgressPresentation.band(
                remainingPercent: remaining,
                durationMinutes: weekly.durationMinutes
            ),
            accessibilityLabel: "每周剩余额度 \(remaining)%\(accessibilitySuffix)"
        )
    }

    private static func unavailable(
        text: String,
        accessibilityLabel: String
    ) -> MenuBarPresentation {
        MenuBarPresentation(
            text: text,
            fillFraction: 0,
            band: nil,
            accessibilityLabel: accessibilityLabel
        )
    }
}
```

Keep the existing app label compiling during this task by changing the body of
`QuotaStore.menuTitle` to read the new model's text:

```swift
var menuTitle: String {
    MenuBarPresentation.make(for: state).text
}
```

Task 2 replaces this temporary text-only bridge with `menuPresentation` when
the custom pill view exists.

- [ ] **Step 4: Run the focused presentation tests**

Run:

```bash
./scripts/test.sh --filter MenuBarPresentationTests
```

Expected: PASS with exit status 0 and no compiler warnings.

- [ ] **Step 5: Commit the presentation model**

```bash
git add Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift \
  Sources/CodexQuotaMenu/UI/QuotaStore.swift \
  Tests/CodexQuotaMenuTests/MenuBarPresentationTests.swift \
  Tests/CodexQuotaMenuTests/QuotaModelsTests.swift
git commit -m "feat: model weekly menu bar quota"
```

---

### Task 2: Percentage-First SwiftUI Pill Label

**Files:**
- Create: `Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift`
- Modify: `Sources/CodexQuotaMenu/UI/QuotaStore.swift`
- Modify: `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift`
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`

**Interfaces:**
- Consumes: `MenuBarPresentation.make(for:)`, `MenuBarPresentation.text`, `fillFraction`, `band`, and `accessibilityLabel` from Task 1.
- Produces: `MenuBarQuotaLabel.init(presentation:)` and `QuotaStore.menuPresentation` for the app label.

- [ ] **Step 1: Add a failing source-contract test for layout and wiring**

Add this test to `PackagingContractTests`:

```swift
@Test
func testMenuBarUsesPercentageFirstQuotaPillAndNoGaugeSymbol() throws {
    let appSource = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift"
        ),
        encoding: .utf8
    )
    let labelSource = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift"
        ),
        encoding: .utf8
    )

    #expect(appSource.contains(
        "MenuBarQuotaLabel(presentation: store.menuPresentation)"
    ))
    #expect(!appSource.contains("gauge.with.dots.needle.50percent"))
    #expect(labelSource.contains("Text(presentation.text)"))
    #expect(labelSource.contains("MenuBarQuotaPill("))
    #expect(labelSource.contains("Color.green"))
    #expect(labelSource.contains("Color.yellow"))
    #expect(labelSource.contains("Color.red"))
    #expect(labelSource.contains("presentation.fillFraction"))
    #expect(labelSource.contains("presentation.accessibilityLabel"))

    let percentage = try #require(
        labelSource.range(of: "Text(presentation.text)")
    )
    let pill = try #require(
        labelSource.range(of: "MenuBarQuotaPill(")
    )
    #expect(percentage.lowerBound < pill.lowerBound)
}
```

- [ ] **Step 2: Run the source-contract test and verify it fails**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests.testMenuBarUsesPercentageFirstQuotaPillAndNoGaugeSymbol
```

Expected: FAIL because `MenuBarQuotaLabel.swift` does not exist and the app
still contains the gauge SF Symbol.

- [ ] **Step 3: Implement the dedicated percentage-first pill view**

Create `Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift`:

```swift
import SwiftUI

struct MenuBarQuotaLabel: View {
    let presentation: MenuBarPresentation

    var body: some View {
        HStack(spacing: 4) {
            Text(presentation.text)
                .monospacedDigit()

            MenuBarQuotaPill(
                fillFraction: presentation.fillFraction,
                band: presentation.band
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct MenuBarQuotaPill: View {
    let fillFraction: Double
    let band: QuotaProgressBand?

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 1)

            GeometryReader { proxy in
                if fillFraction > 0 {
                    Capsule(style: .continuous)
                        .fill(fillColor)
                        .frame(width: proxy.size.width * fillFraction)
                }
            }
            .padding(2)
        }
        .frame(width: 22, height: 10)
        .accessibilityHidden(true)
    }

    private var fillColor: Color {
        switch band {
        case .normal:
            return Color.green
        case .warning:
            return Color.yellow
        case .critical:
            return Color.red
        case nil:
            return Color.clear
        }
    }
}
```

- [ ] **Step 4: Expose the presentation and wire the custom label into the app**

Replace `QuotaStore.menuTitle` in
`Sources/CodexQuotaMenu/UI/QuotaStore.swift` with:

```swift
var menuPresentation: MenuBarPresentation {
    MenuBarPresentation.make(for: state)
}
```

Replace the existing `Label` in the `MenuBarExtra` label closure in
`Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift` with:

```swift
MenuBarQuotaLabel(presentation: store.menuPresentation)
```

- [ ] **Step 5: Run the source-contract and focused presentation tests**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests.testMenuBarUsesPercentageFirstQuotaPillAndNoGaugeSymbol
./scripts/test.sh --filter MenuBarPresentationTests
```

Expected: both commands PASS with exit status 0 and no compiler warnings.

- [ ] **Step 6: Commit the SwiftUI label and app wiring**

```bash
git add Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift \
  Sources/CodexQuotaMenu/UI/QuotaStore.swift \
  Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift \
  Tests/CodexQuotaMenuTests/PackagingContractTests.swift
git commit -m "feat: show weekly quota pill in menu bar"
```

---

### Task 3: Documentation, Full Verification, and Installation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the tested menu-bar label and existing packaging scripts.
- Produces: documented behavior, a verified signed app bundle, and an atomically installed application.

- [ ] **Step 1: Document the menu-bar indicator**

Add this paragraph after the README introduction:

```markdown
The menu bar shows the weekly remaining percentage to the left of a
battery-style pill. The pill fill uses green at 20% or above, yellow from 10%
through 19%, and red below 10%; reset-credit count remains in the popover.
```

- [ ] **Step 2: Run the complete test suite**

Run:

```bash
./scripts/test.sh
```

Expected: PASS with exit status 0 and no compiler warnings.

- [ ] **Step 3: Build and verify the signed application bundle**

Run:

```bash
./scripts/build-app.sh
./scripts/verify-app.sh
```

Expected: both commands exit 0; the bundle is created at
`dist/Codex Quota Menu.app`, passes ad-hoc signature validation, matches the
fresh release executable, and passes the read-only outbound-method audit.

- [ ] **Step 4: Commit the documentation after all repository checks pass**

```bash
git add README.md
git commit -m "docs: describe menu bar quota pill"
```

- [ ] **Step 5: Quit the running copy and atomically install the verified app**

Run:

```bash
osascript -e 'tell application "Codex Quota Menu" to quit'
./scripts/install-app.sh
```

Expected: the installer verifies staging and installed bundles, atomically
replaces `/Applications/Codex Quota Menu.app`, launches one new instance, and
prints `/Applications/Codex Quota Menu.app`.

- [ ] **Step 6: Inspect the real menu bar**

Use the local Mac UI inspection path and verify:

- the visible order is percentage first and pill second;
- no reset-credit count or gauge symbol remains in the menu bar;
- the pill fill length matches the popover's weekly remaining percentage;
- the current threshold color matches green/yellow/red rules;
- clicking the status item still opens the complete popover;
- the popover still shows reset credits, monthly scenario values, refresh,
  launch-at-login, notifications, ChatGPT, and quit controls.

- [ ] **Step 7: Record final repository and installed-bundle evidence**

Run:

```bash
git status --short --branch
codesign --verify --strict '/Applications/Codex Quota Menu.app'
```

Expected: `main` has no uncommitted files from this feature, and `codesign`
exits 0 with no verification error.
