# Dynamic Sol API Scenario Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the misleading fixed Plus/Pro comparison with two explicitly named GPT-5.6 Sol API-cost scenarios displayed on a deterministic dynamic dollar scale.

**Architecture:** Keep monthly usage collection, aggregation, caching, and the two existing price calculations unchanged. Rename the estimator result around its fixed token-mix assumptions, move all dynamic-scale calculation and formatting into the pure presentation model, and keep SwiftUI responsible only for layout, colors, and accessibility copy.

**Tech Stack:** Swift 5.10, SwiftUI on macOS 14+, Foundation `Decimal`/`NumberFormatter`, Swift Testing, existing shell build/sign/install verification scripts.

## Global Constraints

- Continue developing directly on `main`; do not create a feature branch or worktree.
- Keep `account/usage/read`, current-calendar-month aggregation, cache shape, and the five-minute refresh interval unchanged.
- Keep GPT-5.6 Sol standard API scenario rates at exactly `$2.65 / 1M` and `$8.20 / 1M` tokens.
- Define the cached-heavy scenario as `80% cached input, 15% regular input, 5% output` and the output-heavy scenario as `40% cached input, 40% regular input, 20% output`.
- Use the smallest `1`, `2`, `5`, or `10` times a power of ten that is greater than or equal to the output-heavy value, with a minimum track maximum of `$50`.
- Remove Plus `$20`, Pro `$200`, fixed `$250`, benchmark fractions, and all subscription-value verdicts from this feature.
- Keep the menu width at `330` points and keep the monthly value section between quota windows and reset credits.
- Keep the track decorative and hidden from accessibility; the section accessibility label must include both named scenarios, monthly tokens, fixed-mix note, and disclaimer.
- Use the exact visible disclaimer `情景估算，并非实际账单或订阅价值`.
- Do not add a dependency or make any new network request.

---

## File Structure

- `Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift`: owns fixed Sol scenario rates and converts monthly tokens into named scenario dollar values; no UI benchmarks.
- `Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift`: owns display formatting, the nice-number dynamic scale, midpoint/max labels, and clamped track fractions.
- `Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift`: renders the named scenario UI, dynamic track, explanatory copy, and accessibility label.
- `Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift`: proves scenario arithmetic and the absence of benchmark classification behavior.
- `Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift`: proves dynamic-scale boundaries, formatting, fractions, zero usage, and large current-scale usage.
- `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`: source-contract coverage for exact new copy and rejected legacy subscription markers.
- `README.md`: describes the scenarios as hypothetical API costs rather than subscription recovery or measured value.

---

### Task 1: Name the estimator around fixed Sol scenarios

**Files:**
- Modify: `Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift:3-33`
- Modify: `Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift:18-45`
- Modify: `Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift:5-44`

**Interfaces:**
- Consumes: `Int64` current-month token total from `MonthlyUsage.tokens`.
- Produces: `APIEquivalentValueScenarios(cachedHeavyUSD: Decimal, outputHeavyUSD: Decimal)` through `APIEquivalentValueEstimator.estimate(tokens:)`; the old presentation is adapted to this interface so the commit remains buildable before Task 2 removes benchmark presentation entirely.

- [ ] **Step 1: Replace estimator tests with named-scenario expectations**

```swift
@Suite
struct APIEquivalentValueEstimatorTests {
    @Test(arguments: [
        (Int64(0), Decimal(string: "0")!, Decimal(string: "0")!),
        (Int64(1_000_000), Decimal(string: "2.65")!, Decimal(string: "8.20")!),
        (Int64(5_000_000), Decimal(string: "13.25")!, Decimal(string: "41.00")!)
    ])
    func testFixedSolScenarios(
        tokens: Int64,
        cachedHeavy: Decimal,
        outputHeavy: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.estimate(tokens: tokens) == .init(
            cachedHeavyUSD: cachedHeavy,
            outputHeavyUSD: outputHeavy
        ))
    }

    @Test
    func testNegativeTokensCannotProduceNegativeScenarioValues() {
        #expect(APIEquivalentValueEstimator.estimate(tokens: -1) == .init(
            cachedHeavyUSD: 0,
            outputHeavyUSD: 0
        ))
    }

    @Test(arguments: [Decimal(20), Decimal(200)])
    func testTransitionalBenchmarkClassificationRemainsStable(
        benchmark: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark - Decimal(string: "6.75")!,
                outputHeavyUSD: benchmark - Decimal(string: "0.01")!
            ),
            benchmark: benchmark
        ) == .below)
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark - Decimal(string: "6.75")!,
                outputHeavyUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .crossing)
        #expect(APIEquivalentValueEstimator.position(
            scenarios: .init(
                cachedHeavyUSD: benchmark,
                outputHeavyUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .reached)
    }
}
```

- [ ] **Step 2: Run the estimator tests and verify the rename fails first**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValueEstimatorTests
```

Expected: compilation fails because `APIEquivalentValueScenarios`, `cachedHeavyUSD`, and `outputHeavyUSD` do not exist yet.

- [ ] **Step 3: Introduce named scenarios while retaining the benchmark classifier only as a buildable migration bridge**

```swift
import Foundation

struct APIEquivalentValueScenarios: Equatable, Sendable {
    let cachedHeavyUSD: Decimal
    let outputHeavyUSD: Decimal
}

enum BenchmarkPosition: Equatable, Sendable {
    case below
    case crossing
    case reached
}

enum APIEquivalentValueEstimator {
    static let cachedHeavyRatePerMillion = Decimal(string: "2.65")!
    static let outputHeavyRatePerMillion = Decimal(string: "8.20")!

    static func estimate(tokens: Int64) -> APIEquivalentValueScenarios {
        let millions = Decimal(max(tokens, 0)) / Decimal(1_000_000)
        return APIEquivalentValueScenarios(
            cachedHeavyUSD: millions * cachedHeavyRatePerMillion,
            outputHeavyUSD: millions * outputHeavyRatePerMillion
        )
    }

    static func position(
        scenarios: APIEquivalentValueScenarios,
        benchmark: Decimal
    ) -> BenchmarkPosition {
        if scenarios.outputHeavyUSD < benchmark { return .below }
        if scenarios.cachedHeavyUSD >= benchmark { return .reached }
        return .crossing
    }
}
```

- [ ] **Step 4: Adapt the existing presentation initializer to the named estimator interface**

Change only the estimator-dependent lines inside `APIEquivalentValuePresentation.init(usage:)`:

```swift
let scenarios = APIEquivalentValueEstimator.estimate(tokens: usage.tokens)
let formattedLower = Self.dollars(scenarios.cachedHeavyUSD)
let formattedUpper = Self.dollars(scenarios.outputHeavyUSD)
lowerText = formattedLower
upperText = formattedUpper
rangeText = "\(formattedLower)～\(formattedUpper)"
tokenText = Self.tokens(usage.tokens)
lowerFraction = Self.fraction(scenarios.cachedHeavyUSD)
upperFraction = Self.fraction(scenarios.outputHeavyUSD)
plusFraction = Self.fraction(Self.plusBenchmark)
proFraction = Self.fraction(Self.proBenchmark)
statusText = [
    Self.status(
        APIEquivalentValueEstimator.position(
            scenarios: scenarios,
            benchmark: Self.plusBenchmark
        ),
        name: "Plus $20"
    ),
    Self.status(
        APIEquivalentValueEstimator.position(
            scenarios: scenarios,
            benchmark: Self.proBenchmark
        ),
        name: "Pro $200"
    )
].joined(separator: " · ")
```

- [ ] **Step 5: Run the estimator and existing presentation tests and verify the migration commit passes**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValueEstimatorTests
./scripts/test.sh --filter APIEquivalentValuePresentationTests
```

Expected: both focused suites pass with zero failures, proving the interface rename did not alter arithmetic or the pre-migration UI.

- [ ] **Step 6: Commit the independently tested estimator change**

```bash
git add Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift
git commit -m "refactor: name Sol API cost scenarios"
```

Expected: one buildable commit containing the named estimator, its focused tests, and the minimum compatibility adaptation in the old presentation.

---

### Task 2: Add the dynamic scale and render the corrected scenario UI

**Files:**
- Modify: `Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift:5-62`
- Modify: `Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift:5-52`
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift:11-41`
- Modify: `Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift:8-37`
- Modify: `Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift:3-86`
- Modify: `Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift:3-102`

**Interfaces:**
- Consumes: `APIEquivalentValueScenarios` returned by Task 1 and `MonthlyUsage.tokens`.
- Produces: `rangeText`, `tokenText`, `cachedHeavyText`, `outputHeavyText`, `trackMidpointText`, `trackMaximumText`, `cachedHeavyFraction`, and `outputHeavyFraction` on `APIEquivalentValuePresentation`.
- Produces for focused boundary tests: `APIEquivalentValuePresentation.niceTrackMaximum(for: Decimal) -> Decimal`.

- [ ] **Step 1: Remove the transitional benchmark test from the final estimator contract**

Replace `APIEquivalentValueEstimatorTests` with the final scenario-only suite:

```swift
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct APIEquivalentValueEstimatorTests {
    @Test(arguments: [
        (Int64(0), Decimal(string: "0")!, Decimal(string: "0")!),
        (Int64(1_000_000), Decimal(string: "2.65")!, Decimal(string: "8.20")!),
        (Int64(5_000_000), Decimal(string: "13.25")!, Decimal(string: "41.00")!)
    ])
    func testFixedSolScenarios(
        tokens: Int64,
        cachedHeavy: Decimal,
        outputHeavy: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.estimate(tokens: tokens) == .init(
            cachedHeavyUSD: cachedHeavy,
            outputHeavyUSD: outputHeavy
        ))
    }

    @Test
    func testNegativeTokensCannotProduceNegativeScenarioValues() {
        #expect(APIEquivalentValueEstimator.estimate(tokens: -1) == .init(
            cachedHeavyUSD: 0,
            outputHeavyUSD: 0
        ))
    }
}
```

- [ ] **Step 2: Write presentation tests for dynamic scaling, labels, and large values**

Replace `APIEquivalentValuePresentationTests` with:

```swift
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct APIEquivalentValuePresentationTests {
    @Test
    func testFiveMillionTokensUseFiftyDollarScale() {
        let value = presentation(tokens: 5_000_000)

        #expect(value.rangeText == "$13.25～$41.00")
        #expect(value.cachedHeavyText == "$13.25")
        #expect(value.outputHeavyText == "$41.00")
        #expect(value.tokenText == "5.00M tokens")
        #expect(value.trackMidpointText == "$25")
        #expect(value.trackMaximumText == "$50")
        #expect(abs(value.cachedHeavyFraction - 0.265) < 0.000_001)
        #expect(abs(value.outputHeavyFraction - 0.82) < 0.000_001)
    }

    @Test
    func testZeroTokensUseMinimumScaleAndEmptyFills() {
        let value = presentation(tokens: 0)

        #expect(value.rangeText == "$0.00～$0.00")
        #expect(value.trackMidpointText == "$25")
        #expect(value.trackMaximumText == "$50")
        #expect(value.cachedHeavyFraction == 0)
        #expect(value.outputHeavyFraction == 0)
    }

    @Test(arguments: [
        (Decimal(string: "41")!, Decimal(50)),
        (Decimal(string: "50")!, Decimal(50)),
        (Decimal(string: "51")!, Decimal(100)),
        (Decimal(string: "820")!, Decimal(1_000)),
        (Decimal(string: "4032.23")!, Decimal(5_000))
    ])
    func testNiceTrackMaximumBoundaries(value: Decimal, expected: Decimal) {
        #expect(APIEquivalentValuePresentation.niceTrackMaximum(for: value) == expected)
    }

    @Test
    func testCurrentScaleUsageGetsGroupedFiveThousandDollarTrackWithoutSaturation() {
        let value = presentation(tokens: 491_735_161)

        #expect(value.rangeText == "$1303.10～$4032.23")
        #expect(value.trackMidpointText == "$2,500")
        #expect(value.trackMaximumText == "$5,000")
        #expect(value.cachedHeavyFraction > 0)
        #expect(value.cachedHeavyFraction < value.outputHeavyFraction)
        #expect(value.outputHeavyFraction < 1)
    }

    private func presentation(tokens: Int64) -> APIEquivalentValuePresentation {
        APIEquivalentValuePresentation(usage: MonthlyUsage(
            monthStart: .distantPast,
            tokens: tokens,
            fetchedAt: .distantPast
        ))
    }
}
```

- [ ] **Step 3: Change the source-contract test to require the corrected copy and reject legacy markers**

Replace the monthly-value assertions in `testMenuRendersIndependentMonthlyValueSectionWithoutRemovingControls()` with:

```swift
#expect(menuSource.contains("MonthlyUsageValueSection(usage: monthlyUsage)"))
#expect(menuSource.contains("本月使用数据暂不可用"))
#expect(valueSource.contains("Sol API 假设场景"))
#expect(valueSource.contains("缓存较多情景"))
#expect(valueSource.contains("输出较多情景"))
#expect(valueSource.contains("固定构成：80/15/5 · 40/40/20"))
#expect(valueSource.contains("GPT-5.6 Sol 标准 API 价格"))
#expect(valueSource.contains("情景估算，并非实际账单或订阅价值"))
#expect(valueSource.contains(#"Text("情景估算，并非实际账单或订阅价值")"#))
#expect(!valueSource.contains("本月 API 等价价值"))
#expect(!valueSource.contains("Plus $20"))
#expect(!valueSource.contains("Pro $200"))
#expect(!valueSource.contains("$250"))
#expect(!valueSource.contains("statusText"))
#expect(!valueSource.contains("plusFraction"))
#expect(!valueSource.contains("proFraction"))
#expect(menuSource.contains("可用重置次数"))
#expect(menuSource.contains("登录时启动"))
#expect(menuSource.contains("到期通知"))
#expect(menuSource.contains("打开 ChatGPT"))
#expect(menuSource.contains("退出"))
#expect(menuSource.contains(".frame(width: 330)"))
```

- [ ] **Step 4: Run both focused suites and verify they fail against the old fixed-scale UI**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValuePresentationTests
./scripts/test.sh --filter PackagingContractTests.testMenuRendersIndependentMonthlyValueSectionWithoutRemovingControls
```

Expected: presentation compilation/assertions fail for the new properties and dynamic maximum; the packaging test fails because the old title and Plus/Pro markers remain.

- [ ] **Step 5: Implement the pure dynamic-scale presentation model**

Replace `APIEquivalentValuePresentation.swift` with:

```swift
import Foundation

struct APIEquivalentValuePresentation: Equatable, Sendable {
    let rangeText: String
    let tokenText: String
    let cachedHeavyText: String
    let outputHeavyText: String
    let trackMidpointText: String
    let trackMaximumText: String
    let cachedHeavyFraction: Double
    let outputHeavyFraction: Double

    init(usage: MonthlyUsage) {
        let scenarios = APIEquivalentValueEstimator.estimate(tokens: usage.tokens)
        let trackMaximum = Self.niceTrackMaximum(for: scenarios.outputHeavyUSD)

        let formattedCachedHeavy = Self.dollars(scenarios.cachedHeavyUSD)
        let formattedOutputHeavy = Self.dollars(scenarios.outputHeavyUSD)

        cachedHeavyText = formattedCachedHeavy
        outputHeavyText = formattedOutputHeavy
        rangeText = "\(formattedCachedHeavy)～\(formattedOutputHeavy)"
        tokenText = Self.tokens(usage.tokens)
        trackMidpointText = Self.scaleDollars(trackMaximum / 2)
        trackMaximumText = Self.scaleDollars(trackMaximum)
        cachedHeavyFraction = Self.fraction(
            scenarios.cachedHeavyUSD,
            maximum: trackMaximum
        )
        outputHeavyFraction = Self.fraction(
            scenarios.outputHeavyUSD,
            maximum: trackMaximum
        )
    }

    static func niceTrackMaximum(for value: Decimal) -> Decimal {
        let minimum = Decimal(50)
        guard value > minimum else { return minimum }

        var power = Decimal(100)
        while true {
            for multiplier in [Decimal(1), Decimal(2), Decimal(5)] {
                let candidate = power * multiplier
                if value <= candidate { return candidate }
            }
            power *= 10
        }
    }

    private static func fraction(_ value: Decimal, maximum: Decimal) -> Double {
        let raw = NSDecimalNumber(decimal: value / maximum).doubleValue
        return min(max(raw, 0), 1)
    }

    private static func dollars(_ value: Decimal) -> String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            NSDecimalNumber(decimal: value).doubleValue
        )
    }

    private static func scaleDollars(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
        return "$\(number)"
    }

    private static func tokens(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(
                format: "%.2fM tokens",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(value) / 1_000_000
            )
        }
        if value >= 1_000 {
            return String(
                format: "%.2fK tokens",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(value) / 1_000
            )
        }
        return "\(value) tokens"
    }
}
```

- [ ] **Step 6: Remove the transitional benchmark classifier from the estimator**

Replace `APIEquivalentValueEstimator.swift` with its final scenario-only form:

```swift
import Foundation

struct APIEquivalentValueScenarios: Equatable, Sendable {
    let cachedHeavyUSD: Decimal
    let outputHeavyUSD: Decimal
}

enum APIEquivalentValueEstimator {
    static let cachedHeavyRatePerMillion = Decimal(string: "2.65")!
    static let outputHeavyRatePerMillion = Decimal(string: "8.20")!

    static func estimate(tokens: Int64) -> APIEquivalentValueScenarios {
        let millions = Decimal(max(tokens, 0)) / Decimal(1_000_000)
        return APIEquivalentValueScenarios(
            cachedHeavyUSD: millions * cachedHeavyRatePerMillion,
            outputHeavyUSD: millions * outputHeavyRatePerMillion
        )
    }
}
```

- [ ] **Step 7: Run estimator and presentation tests and verify both pure models pass**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValueEstimatorTests
./scripts/test.sh --filter APIEquivalentValuePresentationTests
```

Expected: the scenario-only estimator suite and all dynamic-scale boundary, formatting, zero, and current-scale presentation tests pass.

- [ ] **Step 8: Replace the SwiftUI section with named scenarios and a marker-free dynamic track**

Replace `MonthlyUsageValueSection.swift` with:

```swift
import SwiftUI

struct MonthlyUsageValueSection: View {
    let usage: MonthlyUsage

    private var presentation: APIEquivalentValuePresentation {
        APIEquivalentValuePresentation(usage: usage)
    }

    var body: some View {
        let value = presentation
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sol API 假设场景")
                Spacer()
                Text(value.rangeText).bold()
            }
            UsageValueTrack(presentation: value)
            VStack(alignment: .leading, spacing: 2) {
                Label("缓存较多情景 \(value.cachedHeavyText)", systemImage: "square.fill")
                    .foregroundStyle(.green)
                Label("输出较多情景 \(value.outputHeavyText)", systemImage: "square.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.caption2)
            Text("固定构成：80/15/5 · 40/40/20")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("本月 \(value.tokenText) · GPT-5.6 Sol 标准 API 价格")
                Text("情景估算，并非实际账单或订阅价值")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Sol API 假设场景，缓存较多情景 \(value.cachedHeavyText)，输出较多情景 \(value.outputHeavyText)，本月 \(value.tokenText)，固定构成 80/15/5 与 40/40/20，情景估算，并非实际账单或订阅价值"
        )
    }
}

private struct UsageValueTrack: View {
    let presentation: APIEquivalentValuePresentation

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let cachedHeavyWidth = width * CGFloat(presentation.cachedHeavyFraction)
                let outputHeavyWidth = width * CGFloat(presentation.outputHeavyFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: cachedHeavyWidth)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(outputHeavyWidth - cachedHeavyWidth, 0))
                        .offset(x: cachedHeavyWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: 9)
            HStack {
                Text("$0")
                Spacer()
                Text(presentation.trackMidpointText)
                Spacer()
                Text(presentation.trackMaximumText)
            }
            .font(.system(size: 9))
        }
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 9: Run the source-contract test and scan all production files for legacy semantics**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests.testMenuRendersIndependentMonthlyValueSectionWithoutRemovingControls
rg -n 'BenchmarkPosition|position\(|Plus \$20|Pro \$200|\$250|statusText|plusFraction|proFraction|本月 API 等价价值' Sources
```

Expected: the packaging test passes; `rg` reports no matches and exits with status `1`.

- [ ] **Step 10: Run all estimator, presentation, and packaging tests together**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValueEstimatorTests
./scripts/test.sh --filter APIEquivalentValuePresentationTests
./scripts/test.sh --filter PackagingContractTests
```

Expected: all three focused suites pass with zero failures.

- [ ] **Step 11: Commit the dynamic presentation and corrected UI**

```bash
git add Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift Tests/CodexQuotaMenuTests/PackagingContractTests.swift
git commit -m "feat: scale Sol API scenarios dynamically"
```

Expected: one commit containing the pure presentation model, SwiftUI view, and their focused regression tests.

---

### Task 3: Document, verify, install, and inspect the corrected app

**Files:**
- Modify: `README.md:33-37`
- Generated and verified, not committed: `dist/Codex Quota Menu.app`
- Installed outside the repository after approval: `/Applications/Codex Quota Menu.app`

**Interfaces:**
- Consumes: the complete implementation from Tasks 1 and 2 plus existing `scripts/test.sh`, `scripts/build-app.sh`, `scripts/verify-app.sh`, and `scripts/install-app.sh`.
- Produces: updated user documentation, a signed release bundle, a verified atomic installation, and visible real-runtime acceptance evidence.

- [ ] **Step 1: Update the README to state the assumptions and semantic limits precisely**

Replace the monthly usage paragraph with:

```markdown
The app also reads `account/usage/read` every five minutes and sums only the
current calendar month's date-only usage buckets. It applies two hypothetical
GPT-5.6 Sol standard-API scenarios to that aggregate token total: a cached-heavy
`80/15/5` mix at `$2.65 / 1M` tokens and an output-heavy `40/40/20` mix at
`$8.20 / 1M` tokens. The dynamic track visualizes those scenarios only; the
result is not an OpenAI bill, a savings amount, or a valuation of Plus or Pro.
```

- [ ] **Step 2: Verify documentation and production source contain no subscription-price recovery claim**

Run:

```bash
rg -n 'Plus \$20|Pro \$200|\$250|已达到|可能达到|未达到|subscription price has been recovered' README.md Sources
```

Expected: no matches and `rg` exits with status `1`.

- [ ] **Step 3: Commit the documentation correction**

```bash
git add README.md
git commit -m "docs: explain hypothetical Sol API scenarios"
```

Expected: one documentation-only commit.

- [ ] **Step 4: Run the complete test suite from a clean command invocation**

Run:

```bash
./scripts/test.sh
```

Expected: all non-opt-in tests pass; only the explicitly gated real-account smoke test may be skipped.

- [ ] **Step 5: Build and verify the signed release bundle and outbound-method contract**

Run:

```bash
./scripts/build-app.sh
./scripts/verify-app.sh
./scripts/audit-outbound-methods.sh Sources
```

Expected: release build succeeds; ad-hoc signature, bundle metadata, current-release binary comparison, focused whitelist test, and outbound-method audit all pass. The outbound allowlist remains exactly `initialize`, `initialized`, `account/rateLimits/read`, and `account/usage/read`.

- [ ] **Step 6: Inspect repository state before installation**

Run:

```bash
git status --short
git log -4 --oneline --decorate
```

Expected: no uncommitted tracked changes; the design commit is followed by the estimator, dynamic UI, and documentation commits.

- [ ] **Step 7: Atomically install the verified app with the existing installer**

First quit the running Codex Quota Menu instance. Then run with the required `/Applications` and GUI-launch approval:

```bash
./scripts/install-app.sh
```

Expected: staged verification passes, `/Applications/Codex Quota Menu.app` is atomically replaced, the installed app is re-verified, and the new instance launches. On any post-swap failure, the installer restores the previous app as designed.

- [ ] **Step 8: Prove the installed executable matches the verified bundle**

Run:

```bash
shasum -a 256 "dist/Codex Quota Menu.app/Contents/MacOS/CodexQuotaMenu" "/Applications/Codex Quota Menu.app/Contents/MacOS/CodexQuotaMenu"
```

Expected: both SHA-256 hashes are identical.

- [ ] **Step 9: Inspect the real installed menu-bar UI**

Open the installed app's menu and confirm all of the following in the real runtime:

- title is `Sol API 假设场景`;
- current large usage uses a non-saturated dynamic endpoint such as `$5,000`;
- `缓存较多情景` and `输出较多情景` appear with green/yellow encoding;
- `固定构成：80/15/5 · 40/40/20` is visible;
- `情景估算，并非实际账单或订阅价值` is fully visible;
- no Plus, Pro, `$250`, or subscription-recovery verdict appears;
- weekly quota coloring, quota reset time, reset credits, toggles, ChatGPT button, and quit button remain intact.

Expected: screenshot/visual inspection satisfies every item without truncating the disclaimer.

- [ ] **Step 10: Record final verification evidence and hand off**

Run:

```bash
git status --short
git log -4 --oneline --decorate
```

Expected: clean `main`, all implementation commits present, and no untracked verification artifact requiring source control.
