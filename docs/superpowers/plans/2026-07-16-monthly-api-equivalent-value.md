# Monthly API-Equivalent Value Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, privacy-preserving monthly API-equivalent value track to the macOS menu app and color the weekly remaining-quota track green, yellow, or red at the approved boundaries.

**Architecture:** Extend the existing audited Codex app-server client with one additional read-only `account/usage/read` request performed sequentially after the required rate-limit read. Aggregate date-only daily buckets into an optional `MonthlyUsage`, estimate a GPT-5.6 Sol scenario range through pure domain helpers, and render it in a dedicated SwiftUI section whose `$0～$250` track is independent of quota percentages.

**Tech Stack:** Swift 5, SwiftUI, Foundation `Decimal`, Swift Testing, Swift Package Manager, the existing JSON-lines Codex app-server transport, shell-based outbound-method and bundle audits.

## Global Constraints

- Keep the platform floor at macOS 14 and add no third-party dependency.
- Keep all outbound app-server calls read-only: `initialize`, `initialized`, `account/rateLimits/read`, and `account/usage/read` only.
- Never read Codex conversations, session logs, cookies, credentials, authentication files, or the Codex state database.
- Never transmit usage data to another service and never perform a live pricing-network request.
- Treat `account/rateLimits/read` as required and `account/usage/read` as auxiliary; usage failure must not remove quota or reset-credit data.
- Treat `dailyUsageBuckets == nil` as unavailable, not zero; an empty array is zero.
- Reject malformed dates, negative token counts, and checked-sum overflow rather than understating usage.
- Use fixed GPT-5.6 Sol scenario rates of `$2.65 / 1M` and `$8.20 / 1M` total tokens.
- Use a linear `$0～$250` value track: Plus `$20` at `8%`, Pro `$200` at `80%`, and clipping only above `$250`.
- Color only the weekly (`durationMinutes == 10_080`) remaining-quota track: `>=20%` green, `10...19%` yellow, `<10%` red.
- Keep the menu width at `330` points unless verified real-app text truncation requires a targeted adjustment.
- Preserve reset-credit presentation, expiry notifications, launch-at-login, refresh interval, and footer behavior.
- Do not run the opt-in real-account smoke test or install/open `/Applications/Codex Quota Menu.app` without the required user approval at execution time.

## File Structure

**Create**

- `Sources/CodexQuotaMenu/Domain/MonthlyUsage.swift` — codable monthly token snapshot and pure calendar-month aggregation.
- `Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift` — fixed scenario-price calculation and benchmark state.
- `Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift` — formatting, track fractions, and Chinese benchmark copy.
- `Sources/CodexQuotaMenu/UI/QuotaProgressPresentation.swift` — pure weekly quota color-band selection.
- `Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift` — dedicated SwiftUI value section and `$0～$250` track.
- `Tests/CodexQuotaMenuTests/MonthlyUsageMapperTests.swift` — month, date, token validation, and overflow tests.
- `Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift` — price range and benchmark tests.
- `Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift` — formatting, fractions, and copy tests.
- `Tests/CodexQuotaMenuTests/QuotaProgressPresentationTests.swift` — exact weekly color thresholds.

**Modify**

- `Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift` — account-usage response wire types.
- `Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift` — audited sequential account snapshot read.
- `Sources/CodexQuotaMenu/Services/QuotaReader.swift` — combine required quota data with optional monthly usage.
- `Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift` — attach optional monthly usage without changing existing quota mapping.
- `Sources/CodexQuotaMenu/Domain/QuotaModels.swift` — optional backward-compatible `monthlyUsage` field.
- `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift` — quota tint and placement of the independent value section.
- `Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift` — method order, auxiliary failure, retry, concurrency, and stop behavior.
- `Tests/CodexQuotaMenuTests/QuotaReaderTests.swift` — successful, unavailable, and invalid usage integration.
- `Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift` — monthly-usage passthrough.
- `Tests/CodexQuotaMenuTests/QuotaCacheTests.swift` — new shape and old-cache compatibility.
- `Tests/CodexQuotaMenuTests/PackagingContractTests.swift` — four-method/four-send audit contract and UI source contract.
- `scripts/audit-outbound-methods.sh` — exactly four whitelisted send payloads.
- `scripts/verify-app.sh` — updated focused client test name if renamed.
- `README.md` — data source, fixed-estimate disclaimer, and privacy boundary.

---

### Task 1: Read account usage through the audited app-server client

**Files:**
- Modify: `Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift`
- Modify: `Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift`
- Modify: `Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`
- Modify: `scripts/audit-outbound-methods.sh`
- Modify: `scripts/verify-app.sh`

**Interfaces:**
- Produces: `CodexAccountReadResponse { rateLimits: RateLimitsReadResponse, usage: AccountUsageReadResponse? }`.
- Produces: `CodexAccountReading.readAccountSnapshot() async throws -> CodexAccountReadResponse`.
- Produces: wire types `AccountUsageReadResponse`, `WireDailyUsageBucket`, and `WireAccountUsageSummary`.
- Failure contract: rate-limit failure throws after the existing one retry; usage failure returns `usage == nil`, stops the unhealthy transport, and preserves the successful rate-limit response.

- [ ] **Step 1: Write failing client and audit-contract tests**

Add a client test whose scripted transport returns handshake, rate limits, and usage in that order:

```swift
@Test
func testInitializesThenReadsAccountSnapshotUsingOnlyWhitelistedMethods() async throws {
    let transport = ScriptedJSONLineTransport(lines: [
        #"{"id":0,"result":{"userAgent":"test"}}"#,
        Self.rateLimitsResponse(resetCount: 5),
        #"{"id":2,"result":{"dailyUsageBuckets":[{"startDate":"2026-07-16","tokens":5000000}],"summary":{}}}"#
    ])
    let client = CodexAppServerClient(makeTransport: { transport }, timeoutSeconds: 1)

    let result = try await client.readAccountSnapshot()

    #expect(result.rateLimits.rateLimitResetCredits?.availableCount == 5)
    #expect(result.usage?.dailyUsageBuckets?.first?.tokens == 5_000_000)
    let objects = try await transport.sentLines.map(Self.decodeObject)
    #expect(objects.compactMap { $0["method"] as? String } == [
        "initialize",
        "initialized",
        "account/rateLimits/read",
        "account/usage/read"
    ])
    #expect(objects[2]["id"] as? Int == 1)
    #expect(objects[2]["params"] is NSNull)
    #expect(objects[3]["id"] as? Int == 2)
    #expect(objects[3]["params"] is NSNull)
}

@Test
func testUsageFailureReturnsRateLimitsAndDropsUnhealthyTransport() async throws {
    let transport = ScriptedJSONLineTransport(lines: [
        #"{"id":0,"result":{"userAgent":"test"}}"#,
        Self.rateLimitsResponse(resetCount: 3),
        #"{"id":2,"error":{"code":-32000,"message":"usage unavailable"}}"#
    ])
    let client = CodexAppServerClient(makeTransport: { transport }, timeoutSeconds: 1)

    let result = try await client.readAccountSnapshot()

    #expect(result.rateLimits.rateLimitResetCredits?.availableCount == 3)
    #expect(result.usage == nil)
    #expect(await transport.stopCount == 1)
}

@Test
func testUsageWireModelDistinguishesEmptyAndUnavailableBuckets() throws {
    let decoder = JSONDecoder()
    let empty = try decoder.decode(
        AccountUsageReadResponse.self,
        from: Data(#"{"dailyUsageBuckets":[],"summary":{}}"#.utf8)
    )
    let unavailable = try decoder.decode(
        AccountUsageReadResponse.self,
        from: Data(#"{"dailyUsageBuckets":null,"summary":{}}"#.utf8)
    )
    let missing = try decoder.decode(
        AccountUsageReadResponse.self,
        from: Data(#"{"summary":{}}"#.utf8)
    )

    #expect(empty.dailyUsageBuckets == [])
    #expect(unavailable.dailyUsageBuckets == nil)
    #expect(missing.dailyUsageBuckets == nil)
}
```

Update the existing success fixtures to append this exact usage response:

```swift
private static func usageResponse(tokens: Int64 = 5_000_000) -> String {
    #"{"id":2,"result":{"dailyUsageBuckets":[{"startDate":"2026-07-16","tokens":\#(tokens)}],"summary":{}}}"#
}
```

Update client tests to call `readAccountSnapshot()` and read rate-limit fields through `.rateLimits`. Update expected send-method arrays to append `account/usage/read` only when the usage phase is reached. Preserve all existing timeout, concurrent-read, stop, generation, and one-retry assertions.

In `PackagingContractTests`, make the closed enum expectation exactly:

```swift
#expect(enumCases == [
    "case initialize",
    "case initialized",
    "case rateLimitsRead = \"account/rateLimits/read\"",
    "case usageRead = \"account/usage/read\""
])
#expect(occurrenceCount(of: ".send(", in: clientSource) == 4)
```

- [ ] **Step 2: Run the new test and prove it fails for the missing API**

Run:

```bash
./scripts/test.sh --filter CodexAppServerClientTests.testInitializesThenReadsAccountSnapshotUsingOnlyWhitelistedMethods
```

Expected: compilation fails because `readAccountSnapshot`, `usageRead`, and the usage wire models do not exist.

- [ ] **Step 3: Add wire models and the sequential composite read**

Append these protocol models:

```swift
struct AccountUsageReadResponse: Decodable, Equatable, Sendable {
    let dailyUsageBuckets: [WireDailyUsageBucket]?
    let summary: WireAccountUsageSummary
}

struct WireDailyUsageBucket: Decodable, Equatable, Sendable {
    let startDate: String
    let tokens: Int64
}

struct WireAccountUsageSummary: Decodable, Equatable, Sendable {
    let currentStreakDays: Int64?
    let lifetimeTokens: Int64?
    let longestRunningTurnSec: Int64?
    let longestStreakDays: Int64?
    let peakDailyTokens: Int64?
}
```

Replace the client-facing protocol and in-flight response type with:

```swift
enum AppServerMethod: String, CaseIterable, Sendable {
    case initialize
    case initialized
    case rateLimitsRead = "account/rateLimits/read"
    case usageRead = "account/usage/read"
}

struct CodexAccountReadResponse: Sendable {
    let rateLimits: RateLimitsReadResponse
    let usage: AccountUsageReadResponse?
}

protocol CodexAccountReading: Sendable {
    func readAccountSnapshot() async throws -> CodexAccountReadResponse
}
```

Make `CodexAppServerClient` conform to `CodexAccountReading`, change `InFlightRead.task`, `readWithOneRetry`, and `readOnce` to return `CodexAccountReadResponse`, and rename the public operation to `readAccountSnapshot`. The `readOnce` body must use exactly one receive loop at a time:

```swift
private func readOnce(generation: UInt64) async throws -> CodexAccountReadResponse {
    let transport = try await initializedTransport(generation: generation)
    try ensureCurrent(transport, generation: generation)
    try await transport.send(
        #"{"method":"\#(AppServerMethod.rateLimitsRead.rawValue)","id":1,"params":null}"#
    )
    try ensureCurrent(transport, generation: generation)
    let rateLimits = try await waitForResponse(
        id: 1,
        result: RateLimitsReadResponse.self,
        transport: transport
    )
    try ensureCurrent(transport, generation: generation)

    do {
        try await transport.send(
            #"{"method":"\#(AppServerMethod.usageRead.rawValue)","id":2,"params":null}"#
        )
        try ensureCurrent(transport, generation: generation)
        let usage = try await waitForResponse(
            id: 2,
            result: AccountUsageReadResponse.self,
            transport: transport
        )
        try ensureCurrent(transport, generation: generation)
        return CodexAccountReadResponse(rateLimits: rateLimits, usage: usage)
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        await resetTransport(generation: generation)
        return CodexAccountReadResponse(rateLimits: rateLimits, usage: nil)
    }
}
```

Keep rate-limit retry semantics around this function. A usage failure is caught inside `readOnce`, so it is not mistaken for a failed primary read.

Update `scripts/audit-outbound-methods.sh` to require exactly four references, four enum cases, and four send blocks. Add the exact payload:

```bash
EXPECTED_USAGE='#"{"method":"\#(AppServerMethod.usageRead.rawValue)","id":2,"params":null}"#'
```

Set `GLOBAL_SEND_REFERENCE_COUNT`, `CASE_COUNT`, the awk send-block count,
`SEND_OPENER_COUNT`, `SEND_CLOSER_COUNT`, and `METHOD_KEY_COUNT` to exactly `4`;
set `NONEMPTY_SEND_LINE_COUNT` to exactly `12`. The audit must still reject
`consume|redeem|write`, dynamic methods, sends outside
`CodexAppServerClient.swift`, and any fifth payload. Extend the packaging test's
method-occurrence loop to `["initialize", "initialized", "rateLimitsRead",
"usageRead"]`. Update `scripts/verify-app.sh` to use the renamed focused client
test. Update the cancellation helper signature to
`Result<CodexAccountReadResponse, any Error>`.

- [ ] **Step 4: Run focused protocol, lifecycle, and audit tests**

Run:

```bash
./scripts/test.sh --filter CodexAppServerClientTests
./scripts/test.sh --filter PackagingContractTests
./scripts/audit-outbound-methods.sh Sources
```

Expected: all client and packaging tests pass; the audit prints `Audited outbound methods:` and exits 0.

- [ ] **Step 5: Commit the audited read-only protocol change**

```bash
git add Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift Tests/CodexQuotaMenuTests/PackagingContractTests.swift scripts/audit-outbound-methods.sh scripts/verify-app.sh
git commit -m "feat: read account usage through app server"
```

### Task 2: Aggregate current-calendar-month usage safely

**Files:**
- Create: `Sources/CodexQuotaMenu/Domain/MonthlyUsage.swift`
- Modify: `Sources/CodexQuotaMenu/Domain/QuotaModels.swift`
- Create: `Tests/CodexQuotaMenuTests/MonthlyUsageMapperTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/QuotaCacheTests.swift`

**Interfaces:**
- Produces: `MonthlyUsage { monthStart: Date, tokens: Int64, fetchedAt: Date }`.
- Produces: `MonthlyUsageMapper.map(buckets:now:calendar:) throws -> MonthlyUsage`.
- Produces: `QuotaSnapshot.monthlyUsage: MonthlyUsage?`, defaulting to `nil` for source and cache compatibility.

- [ ] **Step 1: Write failing month aggregation and old-cache tests**

Create tests with an injected Gregorian Shanghai calendar:

```swift
private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

@Test
func testSumsOnlyCurrentMonthDateOnlyBuckets() throws {
    let result = try MonthlyUsageMapper.map(
        buckets: [
            .init(startDate: "2026-06-30", tokens: 7),
            .init(startDate: "2026-07-01", tokens: 2_000_000),
            .init(startDate: "2026-07-16", tokens: 3_000_000),
            .init(startDate: "2026-08-01", tokens: 11)
        ],
        now: Date(timeIntervalSince1970: 1_783_958_400),
        calendar: calendar()
    )

    #expect(result.tokens == 5_000_000)
    #expect(calendar().component(.day, from: result.monthStart) == 1)
}

@Test
func testEmptyBucketsMeanZero() throws {
    let result = try MonthlyUsageMapper.map(
        buckets: [],
        now: Date(timeIntervalSince1970: 1_783_958_400),
        calendar: calendar()
    )
    #expect(result.tokens == 0)
}

@Test(arguments: [
    [WireDailyUsageBucket(startDate: "not-a-date", tokens: 1)],
    [WireDailyUsageBucket(startDate: "2026-02-30", tokens: 1)],
    [WireDailyUsageBucket(startDate: "2026-07-01", tokens: -1)]
])
func testInvalidBucketMakesUsageUnavailable(buckets: [WireDailyUsageBucket]) {
    #expect(throws: MonthlyUsageMappingError.self) {
        try MonthlyUsageMapper.map(
            buckets: buckets,
            now: Date(timeIntervalSince1970: 1_783_958_400),
            calendar: calendar()
        )
    }
}

@Test
func testCheckedSumRejectsOverflow() {
    do {
        _ = try MonthlyUsageMapper.map(
            buckets: [
                .init(startDate: "2026-07-01", tokens: Int64.max),
                .init(startDate: "2026-07-02", tokens: 1)
            ],
            now: Date(timeIntervalSince1970: 1_783_958_400),
            calendar: calendar()
        )
        Issue.record("Expected checked-sum overflow")
    } catch let error as MonthlyUsageMappingError {
        #expect(error == .overflow)
    } catch {
        Issue.record("Expected MonthlyUsageMappingError.overflow, got \(error)")
    }
}

@Test
func testYearBoundaryAndLeapDayRemainDateOnly() throws {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let january = try MonthlyUsageMapper.map(
        buckets: [
            .init(startDate: "2026-12-31", tokens: 1),
            .init(startDate: "2027-01-01", tokens: 2)
        ],
        now: utc.date(from: DateComponents(year: 2027, month: 1, day: 15))!,
        calendar: utc
    )
    let leapFebruary = try MonthlyUsageMapper.map(
        buckets: [.init(startDate: "2028-02-29", tokens: 3)],
        now: utc.date(from: DateComponents(year: 2028, month: 2, day: 29))!,
        calendar: utc
    )

    #expect(january.tokens == 2)
    #expect(leapFebruary.tokens == 3)
}
```

Add a cache test that writes a valid legacy JSON document with only `windows`, `availableResetCount`, `resetCredits`, and `fetchedAt`, then asserts `load()?.monthlyUsage == nil`. Extend the on-disk-shape test with a non-nil monthly usage and assert the only new top-level key is `monthlyUsage` with `monthStart`, `tokens`, and `fetchedAt`.

- [ ] **Step 2: Run the mapper tests and verify missing-type failures**

Run:

```bash
./scripts/test.sh --filter MonthlyUsageMapperTests
```

Expected: compilation fails because `MonthlyUsage`, `MonthlyUsageMapper`, and `QuotaSnapshot.monthlyUsage` do not exist.

- [ ] **Step 3: Implement the codable model and strict date-only mapper**

Create the file with this complete behavior:

```swift
import Foundation

struct MonthlyUsage: Codable, Equatable, Sendable {
    let monthStart: Date
    let tokens: Int64
    let fetchedAt: Date
}

enum MonthlyUsageMappingError: Error, Equatable {
    case invalidCalendar
    case invalidStartDate(String)
    case negativeTokens(Int64)
    case overflow
}

enum MonthlyUsageMapper {
    static func map(
        buckets: [WireDailyUsageBucket],
        now: Date,
        calendar: Calendar
    ) throws -> MonthlyUsage {
        guard let interval = calendar.dateInterval(of: .month, for: now) else {
            throw MonthlyUsageMappingError.invalidCalendar
        }

        var total: Int64 = 0
        for bucket in buckets {
            guard bucket.tokens >= 0 else {
                throw MonthlyUsageMappingError.negativeTokens(bucket.tokens)
            }
            let date = try dateOnly(bucket.startDate, calendar: calendar)
            guard date >= interval.start, date < interval.end else { continue }
            let (next, overflow) = total.addingReportingOverflow(bucket.tokens)
            guard !overflow else { throw MonthlyUsageMappingError.overflow }
            total = next
        }

        return MonthlyUsage(
            monthStart: interval.start,
            tokens: total,
            fetchedAt: now
        )
    }

    private static func dateOnly(_ value: String, calendar: Calendar) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year,
              normalized.month == month,
              normalized.day == day else {
            throw MonthlyUsageMappingError.invalidStartDate(value)
        }
        return date
    }
}
```

Add a manual initializer to `QuotaSnapshot` so existing source call sites remain valid:

```swift
struct QuotaSnapshot: Codable, Equatable, Sendable {
    let windows: [QuotaWindow]
    let availableResetCount: Int
    let resetCredits: [ResetCredit]?
    let monthlyUsage: MonthlyUsage?
    let fetchedAt: Date

    init(
        windows: [QuotaWindow],
        availableResetCount: Int,
        resetCredits: [ResetCredit]?,
        monthlyUsage: MonthlyUsage? = nil,
        fetchedAt: Date
    ) {
        self.windows = windows
        self.availableResetCount = availableResetCount
        self.resetCredits = resetCredits
        self.monthlyUsage = monthlyUsage
        self.fetchedAt = fetchedAt
    }
}
```

Preserve `mostConstrainedRemainingPercent` and `isStale` unchanged beneath the initializer.

- [ ] **Step 4: Run mapper and cache tests**

Run:

```bash
./scripts/test.sh --filter MonthlyUsageMapperTests
./scripts/test.sh --filter QuotaCacheTests
```

Expected: all tests pass, including old-cache decode and non-nil monthly-usage round trip.

- [ ] **Step 5: Commit monthly aggregation and cache compatibility**

```bash
git add Sources/CodexQuotaMenu/Domain/MonthlyUsage.swift Sources/CodexQuotaMenu/Domain/QuotaModels.swift Tests/CodexQuotaMenuTests/MonthlyUsageMapperTests.swift Tests/CodexQuotaMenuTests/QuotaCacheTests.swift
git commit -m "feat: aggregate calendar month token usage"
```

### Task 3: Estimate and present the API-equivalent value range

**Files:**
- Create: `Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift`
- Create: `Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift`
- Create: `Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift`
- Create: `Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift`

**Interfaces:**
- Produces: `APIEquivalentValueRange { lowerUSD: Decimal, upperUSD: Decimal }`.
- Produces: `BenchmarkPosition` with `.below`, `.crossing`, and `.reached`.
- Produces: `APIEquivalentValuePresentation(usage:)` with formatted strings and clamped `$0～$250` fractions.

- [ ] **Step 1: Write failing estimator and presentation tests**

```swift
@Suite
struct APIEquivalentValueEstimatorTests {
    @Test(arguments: [
        (Int64(0), Decimal(string: "0")!, Decimal(string: "0")!),
        (Int64(1_000_000), Decimal(string: "2.65")!, Decimal(string: "8.20")!),
        (Int64(5_000_000), Decimal(string: "13.25")!, Decimal(string: "41.00")!)
    ])
    func testFixedScenarioRange(
        tokens: Int64,
        lower: Decimal,
        upper: Decimal
    ) {
        #expect(APIEquivalentValueEstimator.estimate(tokens: tokens) == .init(
            lowerUSD: lower,
            upperUSD: upper
        ))
    }

    @Test(arguments: [Decimal(20), Decimal(200)])
    func testBenchmarkPositionsAtPlusAndPro(benchmark: Decimal) {
        #expect(APIEquivalentValueEstimator.position(
            range: .init(
                lowerUSD: benchmark - Decimal(string: "6.75")!,
                upperUSD: benchmark - Decimal(string: "0.01")!
            ),
            benchmark: benchmark
        ) == .below)
        #expect(APIEquivalentValueEstimator.position(
            range: .init(
                lowerUSD: benchmark - Decimal(string: "6.75")!,
                upperUSD: benchmark + Decimal(21)
            ),
            benchmark: benchmark
        ) == .crossing)
        #expect(APIEquivalentValueEstimator.position(
            range: .init(lowerUSD: benchmark, upperUSD: benchmark + Decimal(21)),
            benchmark: benchmark
        ) == .reached)
    }
}

@Suite
struct APIEquivalentValuePresentationTests {
    @Test
    func testFiveMillionTokenPresentationUsesApprovedScaleAndCopy() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 5_000_000,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.rangeText == "$13.25～$41.00")
        #expect(value.tokenText == "5.00M tokens")
        #expect(abs(value.lowerFraction - 0.053) < 0.000_001)
        #expect(abs(value.upperFraction - 0.164) < 0.000_001)
        #expect(value.plusFraction == 0.08)
        #expect(value.proFraction == 0.80)
        #expect(value.statusText == "可能达到 Plus $20 · 未达到 Pro $200")
    }

    @Test
    func testTrackFractionsClipAtTwoHundredFiftyWithoutClippingText() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 100_000_000,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.upperFraction == 1)
        #expect(value.rangeText == "$265.00～$820.00")
    }

    @Test
    func testZeroTokensShowZeroRangeAndEmptyFill() {
        let usage = MonthlyUsage(
            monthStart: .distantPast,
            tokens: 0,
            fetchedAt: .distantPast
        )
        let value = APIEquivalentValuePresentation(usage: usage)

        #expect(value.rangeText == "$0.00～$0.00")
        #expect(value.lowerFraction == 0)
        #expect(value.upperFraction == 0)
        #expect(value.statusText == "未达到 Plus $20 · 未达到 Pro $200")
    }
}
```

- [ ] **Step 2: Run tests and verify missing estimator failures**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValue
```

Expected: compilation fails because the estimator and presentation types do not exist.

- [ ] **Step 3: Implement exact Decimal pricing and benchmark logic**

```swift
import Foundation

struct APIEquivalentValueRange: Equatable, Sendable {
    let lowerUSD: Decimal
    let upperUSD: Decimal
}

enum BenchmarkPosition: Equatable, Sendable {
    case below
    case crossing
    case reached
}

enum APIEquivalentValueEstimator {
    static let lowerRatePerMillion = Decimal(string: "2.65")!
    static let upperRatePerMillion = Decimal(string: "8.20")!

    static func estimate(tokens: Int64) -> APIEquivalentValueRange {
        let millions = Decimal(max(tokens, 0)) / Decimal(1_000_000)
        return APIEquivalentValueRange(
            lowerUSD: millions * lowerRatePerMillion,
            upperUSD: millions * upperRatePerMillion
        )
    }

    static func position(
        range: APIEquivalentValueRange,
        benchmark: Decimal
    ) -> BenchmarkPosition {
        if range.upperUSD < benchmark { return .below }
        if range.lowerUSD >= benchmark { return .reached }
        return .crossing
    }
}
```

- [ ] **Step 4: Implement formatting and `$0～$250` fractions**

```swift
import Foundation

struct APIEquivalentValuePresentation: Equatable, Sendable {
    static let trackMaximum = Decimal(250)
    static let plusBenchmark = Decimal(20)
    static let proBenchmark = Decimal(200)

    let rangeText: String
    let tokenText: String
    let statusText: String
    let lowerText: String
    let upperText: String
    let lowerFraction: Double
    let upperFraction: Double
    let plusFraction: Double
    let proFraction: Double

    init(usage: MonthlyUsage) {
        let range = APIEquivalentValueEstimator.estimate(tokens: usage.tokens)
        let formattedLower = Self.dollars(range.lowerUSD)
        let formattedUpper = Self.dollars(range.upperUSD)
        lowerText = formattedLower
        upperText = formattedUpper
        rangeText = "\(formattedLower)～\(formattedUpper)"
        tokenText = Self.tokens(usage.tokens)
        lowerFraction = Self.fraction(range.lowerUSD)
        upperFraction = Self.fraction(range.upperUSD)
        plusFraction = Self.fraction(Self.plusBenchmark)
        proFraction = Self.fraction(Self.proBenchmark)
        statusText = [
            Self.status(
                APIEquivalentValueEstimator.position(
                    range: range,
                    benchmark: Self.plusBenchmark
                ),
                name: "Plus $20"
            ),
            Self.status(
                APIEquivalentValueEstimator.position(
                    range: range,
                    benchmark: Self.proBenchmark
                ),
                name: "Pro $200"
            )
        ].joined(separator: " · ")
    }

    private static func fraction(_ value: Decimal) -> Double {
        let raw = NSDecimalNumber(decimal: value / trackMaximum).doubleValue
        return min(max(raw, 0), 1)
    }

    private static func dollars(_ value: Decimal) -> String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            NSDecimalNumber(decimal: value).doubleValue
        )
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

    private static func status(_ position: BenchmarkPosition, name: String) -> String {
        switch position {
        case .below: return "未达到 \(name)"
        case .crossing: return "可能达到 \(name)"
        case .reached: return "已达到 \(name)"
        }
    }
}
```

- [ ] **Step 5: Run estimator and presentation tests**

Run:

```bash
./scripts/test.sh --filter APIEquivalentValue
```

Expected: all estimator and presentation tests pass, including `8%`, `80%`, and text-unclipped behavior.

- [ ] **Step 6: Commit the pure value model**

```bash
git add Sources/CodexQuotaMenu/Domain/APIEquivalentValueEstimator.swift Sources/CodexQuotaMenu/UI/APIEquivalentValuePresentation.swift Tests/CodexQuotaMenuTests/APIEquivalentValueEstimatorTests.swift Tests/CodexQuotaMenuTests/APIEquivalentValuePresentationTests.swift
git commit -m "feat: estimate monthly API equivalent value"
```

### Task 4: Integrate optional monthly usage into refresh and cache flow

**Files:**
- Modify: `Sources/CodexQuotaMenu/Services/QuotaReader.swift`
- Modify: `Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift`
- Modify: `Tests/CodexQuotaMenuTests/QuotaReaderTests.swift`
- Modify: `Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift`

**Interfaces:**
- Consumes: `CodexAccountReading.readAccountSnapshot()` from Task 1.
- Consumes: `MonthlyUsageMapper.map(buckets:now:calendar:)` from Task 2.
- Produces: every successful primary read returns a `QuotaSnapshot` whose `monthlyUsage` is populated or `nil` without disturbing windows/reset credits.

- [ ] **Step 1: Write failing reader integration tests**

Replace the simple rate-limit stub with:

```swift
private struct StubCodexAccountReader: CodexAccountReading {
    let response: CodexAccountReadResponse

    func readAccountSnapshot() async throws -> CodexAccountReadResponse {
        response
    }
}
```

Add these cases:

```swift
@Test
func testReaderAttachesCurrentMonthUsage() async throws {
    let fixed = Date(timeIntervalSince1970: 1_783_958_400)
    let reader = LiveQuotaReader(
        client: StubCodexAccountReader(response: .init(
            rateLimits: Self.response,
            usage: AccountUsageReadResponse(
                dailyUsageBuckets: [
                    .init(startDate: "2026-07-01", tokens: 2_000_000),
                    .init(startDate: "2026-07-16", tokens: 3_000_000)
                ],
                summary: Self.emptyUsageSummary
            )
        )),
        now: { fixed },
        calendar: Self.shanghaiCalendar
    )

    let snapshot = try await reader.read()

    #expect(snapshot.monthlyUsage?.tokens == 5_000_000)
    #expect(snapshot.windows.isEmpty == false)
    #expect(snapshot.availableResetCount == 2)
}

@Test
func testNilOrInvalidUsageDoesNotRemoveRateLimits() async throws {
    let nilUsage = LiveQuotaReader(
        client: StubCodexAccountReader(response: .init(
            rateLimits: Self.response,
            usage: nil
        )),
        now: { .distantPast }
    )
    let invalidUsage = LiveQuotaReader(
        client: StubCodexAccountReader(response: .init(
            rateLimits: Self.response,
            usage: .init(
                dailyUsageBuckets: [.init(startDate: "bad", tokens: 1)],
                summary: Self.emptyUsageSummary
            )
        )),
        now: { .distantPast }
    )
    let nilBuckets = LiveQuotaReader(
        client: StubCodexAccountReader(response: .init(
            rateLimits: Self.response,
            usage: .init(
                dailyUsageBuckets: nil,
                summary: Self.emptyUsageSummary
            )
        )),
        now: { .distantPast }
    )

    #expect(try await nilUsage.read().monthlyUsage == nil)
    #expect(try await invalidUsage.read().monthlyUsage == nil)
    #expect(try await nilBuckets.read().monthlyUsage == nil)
    #expect(try await nilUsage.read().windows.isEmpty == false)
}
```

Define the test fixture exactly once inside `QuotaReaderTests`:

```swift
private static let emptyUsageSummary = WireAccountUsageSummary(
    currentStreakDays: nil,
    lifetimeTokens: nil,
    longestRunningTurnSec: nil,
    longestStreakDays: nil,
    peakDailyTokens: nil
)
```

- [ ] **Step 2: Run reader tests and verify protocol mismatch failures**

Run:

```bash
./scripts/test.sh --filter QuotaReaderTests
```

Expected: compilation fails until `LiveQuotaReader` consumes `CodexAccountReading` and accepts an injected calendar.

- [ ] **Step 3: Map one captured timestamp into quota and usage**

Change `QuotaResponseMapper.map` to accept the optional value with a default:

```swift
static func map(
    _ response: RateLimitsReadResponse,
    monthlyUsage: MonthlyUsage? = nil,
    fetchedAt: Date
) throws -> QuotaSnapshot
```

Pass `monthlyUsage` into the returned `QuotaSnapshot` and leave window/reset-credit logic byte-for-byte equivalent.

Update `LiveQuotaReader` to use one timestamp for both models:

```swift
struct LiveQuotaReader: QuotaReading {
    let client: any CodexAccountReading
    let now: @Sendable () -> Date
    let calendar: Calendar

    init(
        client: any CodexAccountReading,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.client = client
        self.now = now
        self.calendar = calendar
    }

    func read() async throws -> QuotaSnapshot {
        let response = try await client.readAccountSnapshot()
        let fetchedAt = now()
        let monthlyUsage: MonthlyUsage?
        if let buckets = response.usage?.dailyUsageBuckets {
            monthlyUsage = try? MonthlyUsageMapper.map(
                buckets: buckets,
                now: fetchedAt,
                calendar: calendar
            )
        } else {
            monthlyUsage = nil
        }
        return try QuotaResponseMapper.map(
            response.rateLimits,
            monthlyUsage: monthlyUsage,
            fetchedAt: fetchedAt
        )
    }

    func shutdown() async {}
}
```

Rename `ProductionRateLimitsClient` to `ProductionAccountClient`, conform it to `CodexAccountReading`, and update the factory and test doubles. Preserve the actor lifecycle, one client per generation, stdio arguments, shutdown idempotence, and cancellation behavior.

- [ ] **Step 4: Run reader, mapper, store, and cache regression tests**

Run:

```bash
./scripts/test.sh --filter QuotaReaderTests
./scripts/test.sh --filter QuotaResponseMapperTests
./scripts/test.sh --filter QuotaStoreTests
./scripts/test.sh --filter QuotaCacheTests
```

Expected: all pass; usage errors produce `monthlyUsage == nil`, while primary failures still follow the existing stale/unavailable behavior.

- [ ] **Step 5: Commit refresh integration**

```bash
git add Sources/CodexQuotaMenu/Services/QuotaReader.swift Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift Tests/CodexQuotaMenuTests/QuotaReaderTests.swift Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift
git commit -m "feat: attach optional monthly usage to quota snapshots"
```

### Task 5: Apply approved weekly quota colors

**Files:**
- Create: `Sources/CodexQuotaMenu/UI/QuotaProgressPresentation.swift`
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaProgressPresentationTests.swift`

**Interfaces:**
- Produces: `QuotaProgressBand?` where `nil` means preserve the existing tint for non-weekly windows.
- Consumes: `QuotaWindow.remainingPercent` and `durationMinutes`.

- [ ] **Step 1: Write exact boundary tests**

```swift
import Testing
@testable import CodexQuotaMenu

@Suite
struct QuotaProgressPresentationTests {
    @Test(arguments: [
        (9, QuotaProgressBand.critical),
        (10, QuotaProgressBand.warning),
        (19, QuotaProgressBand.warning),
        (20, QuotaProgressBand.normal),
        (100, QuotaProgressBand.normal)
    ])
    func testWeeklyBoundaries(remaining: Int, expected: QuotaProgressBand) {
        #expect(QuotaProgressPresentation.band(
            remainingPercent: remaining,
            durationMinutes: 10_080
        ) == expected)
    }

    @Test
    func testNonWeeklyWindowRetainsExistingTint() {
        #expect(QuotaProgressPresentation.band(
            remainingPercent: 5,
            durationMinutes: 300
        ) == nil)
    }
}
```

- [ ] **Step 2: Run the boundary tests and verify missing-type failures**

Run:

```bash
./scripts/test.sh --filter QuotaProgressPresentationTests
```

Expected: compilation fails because `QuotaProgressBand` and `QuotaProgressPresentation` do not exist.

- [ ] **Step 3: Implement the pure band selector and SwiftUI tint mapping**

```swift
enum QuotaProgressBand: Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum QuotaProgressPresentation {
    static func band(
        remainingPercent: Int,
        durationMinutes: Int?
    ) -> QuotaProgressBand? {
        guard durationMinutes == 10_080 else { return nil }
        if remainingPercent < 10 { return .critical }
        if remainingPercent < 20 { return .warning }
        return .normal
    }
}
```

Apply `.tint(quotaTint(for: window))` to the existing `ProgressView` and add:

```swift
private func quotaTint(for window: QuotaWindow) -> Color {
    switch QuotaProgressPresentation.band(
        remainingPercent: window.remainingPercent,
        durationMinutes: window.durationMinutes
    ) {
    case .normal: return .green
    case .warning: return .yellow
    case .critical: return .red
    case nil: return .accentColor
    }
}
```

Do not alter the progress value, total, labels, or reset dates.

- [ ] **Step 4: Run color and UI compilation tests**

Run:

```bash
./scripts/test.sh --filter QuotaProgressPresentationTests
./scripts/test.sh --filter QuotaModelsTests
```

Expected: tests pass; exact `20%` is normal/green and exact `10%` is warning/yellow.

- [ ] **Step 5: Commit the weekly color behavior**

```bash
git add Sources/CodexQuotaMenu/UI/QuotaProgressPresentation.swift Sources/CodexQuotaMenu/UI/MenuBarContentView.swift Tests/CodexQuotaMenuTests/QuotaProgressPresentationTests.swift
git commit -m "feat: color weekly quota by remaining percent"
```

### Task 6: Render the independent monthly value track

**Files:**
- Create: `Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift`
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift`
- Modify: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `MonthlyUsage` and `APIEquivalentValuePresentation`.
- Produces: a standalone accessible section with independent fill fractions and fixed Plus/Pro markers.
- Placement: after all quota windows, before reset-credit count and rows.

- [ ] **Step 1: Add a failing source contract for the independent value section**

Extend `PackagingContractTests` to read both UI source files and assert:

```swift
#expect(menuSource.contains("MonthlyUsageValueSection(usage: monthlyUsage)"))
#expect(menuSource.contains("本月使用数据暂不可用"))
#expect(valueSource.contains("本月 API 等价价值"))
#expect(valueSource.contains("Plus $20"))
#expect(valueSource.contains("Pro $200"))
#expect(valueSource.contains("$250"))
#expect(valueSource.contains("GPT-5.6 Sol"))
#expect(valueSource.contains("API 等价估算，并非实际账单"))
```

Also assert `MenuBarContentView.swift` still contains the existing reset-credit, login, notification, ChatGPT, and quit labels.

- [ ] **Step 2: Run the UI source contract and prove the section is absent**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests
```

Expected: failure because `MonthlyUsageValueSection.swift` and the new copy do not exist.

- [ ] **Step 3: Implement the dedicated SwiftUI value section**

Create this structure, keeping all geometry local to the value view:

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
                Text("本月 API 等价价值")
                Spacer()
                Text(value.rangeText).bold()
            }
            UsageValueTrack(presentation: value)
            HStack(spacing: 12) {
                Label("低估 \(value.lowerText)", systemImage: "square.fill")
                    .foregroundStyle(.green)
                Label("高估 \(value.upperText)", systemImage: "square.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.caption2)
            Text(value.statusText)
                .font(.caption)
                .foregroundStyle(.yellow)
            Text("本月 \(value.tokenText) · GPT-5.6 Sol · API 等价估算，并非实际账单")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "本月 API 等价价值 \(value.rangeText)，\(value.statusText)，本月 \(value.tokenText)，并非实际账单"
        )
    }
}

private struct UsageValueTrack: View {
    let presentation: APIEquivalentValuePresentation

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let lowerWidth = width * CGFloat(presentation.lowerFraction)
                let upperWidth = width * CGFloat(presentation.upperFraction)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(height: 9)
                        .offset(y: 11)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: lowerWidth, height: 9)
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.green, .yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(upperWidth - lowerWidth, 0), height: 9)
                            .offset(x: lowerWidth)
                    }
                    .frame(width: width, height: 9, alignment: .leading)
                    .clipShape(Capsule())
                    .offset(y: 11)
                    marker(color: .red, height: 29)
                        .offset(x: width * CGFloat(presentation.plusFraction) - 1)
                    marker(color: .purple, height: 29)
                        .offset(x: width * CGFloat(presentation.proFraction) - 1)
                }
            }
            .frame(height: 31)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .topLeading) {
                    Text("$0").position(x: 6, y: 6)
                    Text("Plus $20").foregroundStyle(.red)
                        .position(x: max(26, width * CGFloat(presentation.plusFraction)), y: 6)
                    Text("Pro $200").foregroundStyle(.purple)
                        .position(x: width * CGFloat(presentation.proFraction), y: 6)
                    Text("$250").position(x: width - 14, y: 6)
                }
                .font(.system(size: 9))
            }
            .frame(height: 12)
        }
        .accessibilityHidden(true)
    }

    private func marker(color: Color, height: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: 2, height: height)
    }
}
```

- [ ] **Step 4: Insert the section between quota and reset credits**

In `quotaContent`, after the quota-window `ForEach`, add:

```swift
Divider()
if let monthlyUsage = snapshot.monthlyUsage {
    MonthlyUsageValueSection(usage: monthlyUsage)
} else {
    Text("本月使用数据暂不可用")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("本月 API 等价价值暂不可用")
}
Divider()
```

Remove the old single divider immediately before `可用重置次数` so there are exactly two boundaries: quota/value and value/reset credits. Keep the outer menu frame at `330` points.

Update `README.md` with these exact facts:

```markdown
The app also reads `account/usage/read` every five minutes and sums only the
current calendar month's date-only usage buckets. It converts total tokens into
a GPT-5.6 Sol API-equivalent range using fixed `$2.65 / 1M` and `$8.20 / 1M`
scenarios. This is an estimate, not an OpenAI bill or a valuation of all Plus or
Pro subscription features.
```

In the privacy section, state that the app still does not inspect conversation or session logs and caches only the derived monthly token total, month start, and fetch time.

- [ ] **Step 5: Run UI contracts, full tests, and a debug build**

Run:

```bash
./scripts/test.sh --filter PackagingContractTests
./scripts/test.sh
```

Expected: all tests pass and the test build completes without warnings.

- [ ] **Step 6: Commit the value UI and documentation**

```bash
git add Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift Sources/CodexQuotaMenu/UI/MenuBarContentView.swift Tests/CodexQuotaMenuTests/PackagingContractTests.swift README.md
git commit -m "feat: show monthly API equivalent value"
```

### Task 7: Verify, package, install, and inspect the real app

**Files:**
- Verify only: all source, test, script, resource, and generated app-bundle inputs.
- Modify only if verification fails: the specific file implicated by the failure or real-app truncation evidence.

**Interfaces:**
- Consumes: all prior task deliverables.
- Produces: a verified release bundle and, after approval, an installed app proven in the actual menu-bar runtime.

- [ ] **Step 1: Confirm a clean implementation diff and review commit scope**

Run:

```bash
git status --short
git log --oneline -8
git diff 31fe3be..HEAD --stat
```

Expected: only planned source/test/script/README files changed, with one focused commit per task and no untracked implementation artifacts.

- [ ] **Step 2: Run the full verification pipeline**

Run:

```bash
./scripts/test.sh
./scripts/build-app.sh
./scripts/verify-app.sh
```

Expected: all tests pass, the release bundle is signed ad hoc, the executable byte comparison passes, and the outbound audit reports exactly the four approved methods.

- [ ] **Step 3: Review the implementation against the approved design**

Check each invariant directly:

```bash
rg -n 'account/usage/read|2\.65|8\.20|Decimal\(250\)|Plus \$20|Pro \$200|durationMinutes == 10_080|本月使用数据暂不可用|并非实际账单' Sources Tests README.md scripts
```

Expected: every design constant and fallback appears in its planned focused unit; no conversation-log path, credential path, mutation method, or network-pricing code exists.

- [ ] **Step 4: Request approval and install the verified bundle**

After receiving approval for the `/Applications` write and GUI launch, run:

```bash
./scripts/install-app.sh
```

Expected: `/Applications/Codex Quota Menu.app` is atomically replaced, re-verified, and opened as a new instance. Do not run `RUN_LIVE_CODEX_TESTS=1` unless the user separately approves that opt-in test.

- [ ] **Step 5: Inspect the real menu-bar window**

Use the real installed app, not a SwiftUI source preview, and verify:

```text
1. Weekly and monthly-value tracks are vertically separate.
2. Weekly >=20% is green; if the live value cannot exercise 20% or 10%, rely on the boundary unit tests rather than altering account data.
3. Plus marker is at 8%, Pro marker is at 80%, and $250 is visible at the right endpoint.
4. The lower/upper fill comes from monthly tokens and is independent of weekly remaining percent.
5. Reset-credit rows, toggles, refresh, ChatGPT button, and quit button remain usable.
6. No text truncates at the 330-point menu width.
7. Usage-unavailable state leaves quota/reset-credit data visible.
```

If width is the only real-app failure, make the smallest evidence-based width or label-spacing adjustment, add/update a source contract, rerun Steps 2–5, and commit with `fix: fit monthly value labels in menu`.

- [ ] **Step 6: Record final repository state**

Run:

```bash
git status --short
git log -7 --oneline
```

Expected: clean worktree and all feature commits present locally. Do not push to GitHub unless the user explicitly requests that external update.
