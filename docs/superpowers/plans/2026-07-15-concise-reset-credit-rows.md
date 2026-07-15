# Concise Reset Credit Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace verbose backend reset-credit titles and descriptions with numbered Chinese rows such as `第一次` and `到期：2026年7月18日 8:42`.

**Architecture:** Add one pure presentation helper that maps a one-based row position to a Chinese ordinal label, then have `MenuBarContentView` enumerate the already-sorted credit array and render only that label plus the existing localized expiration time. A source contract test protects the SwiftUI wiring and prevents backend title/description text from returning.

**Tech Stack:** Swift 6, SwiftUI, Foundation, Apple Swift Testing, SwiftPM, macOS 14+

## Global Constraints

- Each credit uses one main row: Chinese ordinal on the left and `到期：<localized date and time>` on the right.
- Preserve the existing orange `即将到期` indicator beneath the right-side expiration time.
- A missing expiration renders `到期：不过期`.
- Never render `credit.title`, `credit.detail`, `Full reset`, or the backend English description in this UI.
- Do not change response mapping, cache schema, notification scheduling, sorting, available count, privacy, login, or transport behavior.
- Use `./scripts/test.sh` for all tests in the mixed Command Line Tools environment.

---

### Task 1: Render concise numbered reset-credit rows

**Files:**
- Create: `Sources/CodexQuotaMenu/UI/ResetCreditRowPresentation.swift`
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift:122-172`
- Create: `Tests/CodexQuotaMenuTests/ResetCreditRowPresentationTests.swift`

**Interfaces:**
- Consumes: `ResetCredit` values already sorted by `QuotaResponseMapper`, `ResetCreditUrgency.statusText(expiresAt:now:)`, and localized `Date.formatted(date:time:)`.
- Produces: `ResetCreditRowPresentation.ordinalLabel(position: Int) -> String`, where `position` is one-based; `MenuBarContentView` calls it for each enumerated credit.

- [ ] **Step 1: Write the failing ordinal-label tests**

Create `Tests/CodexQuotaMenuTests/ResetCreditRowPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct ResetCreditRowPresentationTests {
    @Test
    func testFirstTenPositionsUseChineseOrdinalLabels() {
        let labels = (1...10).map(ResetCreditRowPresentation.ordinalLabel)

        #expect(labels == [
            "第一次", "第二次", "第三次", "第四次", "第五次",
            "第六次", "第七次", "第八次", "第九次", "第十次"
        ])
    }

    @Test
    func testLargerPositionUsesUnambiguousNumericFallback() {
        #expect(ResetCreditRowPresentation.ordinalLabel(position: 11) == "第11次")
    }
}
```

- [ ] **Step 2: Run the ordinal tests and verify RED**

Run:

```bash
./scripts/test.sh --filter ResetCreditRowPresentationTests
```

Expected: compilation fails because `ResetCreditRowPresentation` does not exist.

- [ ] **Step 3: Add the minimal pure ordinal helper**

Create `Sources/CodexQuotaMenu/UI/ResetCreditRowPresentation.swift`:

```swift
import Foundation

enum ResetCreditRowPresentation {
    private static let chineseNumerals = [
        "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"
    ]

    static func ordinalLabel(position: Int) -> String {
        precondition(position > 0)
        guard position <= chineseNumerals.count else {
            return "第\(position)次"
        }
        return "第\(chineseNumerals[position - 1])次"
    }
}
```

- [ ] **Step 4: Run the ordinal tests and verify GREEN**

Run:

```bash
./scripts/test.sh --filter ResetCreditRowPresentationTests
```

Expected: 2 tests pass with zero warnings.

- [ ] **Step 5: Add a failing SwiftUI source contract test**

Append this test and helper inside `ResetCreditRowPresentationTests`:

```swift
    @Test
    func testMenuRowsUseOrdinalAndExpirationWithoutBackendCopy() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/CodexQuotaMenu/UI/MenuBarContentView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("credits.enumerated()"))
        #expect(source.contains("ResetCreditRowPresentation.ordinalLabel"))
        #expect(source.contains("到期："))
        #expect(!source.contains("credit.title"))
        #expect(!source.contains("credit.detail"))
        #expect(!source.contains("Full reset"))
    }

    private static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
```

- [ ] **Step 6: Run the source contract test and verify RED**

Run:

```bash
./scripts/test.sh --filter ResetCreditRowPresentationTests.testMenuRowsUseOrdinalAndExpirationWithoutBackendCopy
```

Expected: the test fails because the current view renders `credit.title`, `credit.detail`, and `Full reset`, and does not enumerate credits or add `到期：`.

- [ ] **Step 7: Implement the concise SwiftUI row**

Replace `resetCredits` and `resetCreditRow` in `MenuBarContentView.swift` with:

```swift
    @ViewBuilder
    private func resetCredits(_ credits: [ResetCredit]?) -> some View {
        if let credits {
            ForEach(Array(credits.enumerated()), id: \.element.id) { item in
                resetCreditRow(item.element, position: item.offset + 1)
            }
        } else {
            Text("到期详情暂不可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetCreditRow(_ credit: ResetCredit, position: Int) -> some View {
        let urgentStatus = ResetCreditUrgency.statusText(
            expiresAt: credit.expiresAt,
            now: now()
        )
        let expiration = credit.expiresAt?.formatted(
            date: .abbreviated,
            time: .shortened
        ) ?? "不过期"

        return HStack(alignment: .top) {
            Text(ResetCreditRowPresentation.ordinalLabel(position: position))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("到期：\(expiration)")
                    .foregroundStyle(
                        urgentStatus == nil ? Color.secondary : Color.orange
                    )
                if let urgentStatus {
                    Label(
                        urgentStatus,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
    }
```

- [ ] **Step 8: Run focused presentation tests and verify GREEN**

Run:

```bash
./scripts/test.sh --filter ResetCreditRowPresentationTests
```

Expected: 3 tests pass with zero warnings.

- [ ] **Step 9: Run all regression and packaging gates**

Run each command separately:

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh
git diff --check
git status --short
```

Expected: all tests pass; release build and signed bundle verification pass;
the diff check is clean; only the three task files are modified/untracked.

- [ ] **Step 10: Commit the implementation**

```bash
git add Sources/CodexQuotaMenu/UI/ResetCreditRowPresentation.swift Sources/CodexQuotaMenu/UI/MenuBarContentView.swift Tests/CodexQuotaMenuTests/ResetCreditRowPresentationTests.swift
git commit -m "feat: simplify reset credit rows"
```

- [ ] **Step 11: Review and update the installed app**

Create a fresh review package from `88bba20` to the implementation commit and
obtain a read-only task-scoped review. Fix all Critical and Important findings,
then repeat Steps 8-10 as needed. After a clean review, the controller quits the
running installed copy, runs `./scripts/install-app.sh` with `/Applications`
approval, and confirms the relaunched app owns exactly one ChatGPT-bundled
`codex app-server --stdio` child.
