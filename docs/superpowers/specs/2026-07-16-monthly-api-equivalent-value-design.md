# Monthly API-Equivalent Value Design

## Goal

Add a privacy-preserving monthly usage-value estimate to the macOS menu-bar app.
The estimate answers a narrow question: if the current calendar month's Codex
tokens were purchased through the API using a GPT-5.6 Sol-like workload mix,
roughly how much would they cost, and how does that range compare with the
ChatGPT Plus `$20` and Pro `$200` monthly subscription prices?

This is an **API-equivalent estimate**, not an OpenAI bill and not a valuation
of every ChatGPT subscription feature.

## Approved user experience

The menu keeps the existing title, refresh button, reset-credit list, settings,
and footer. The quota and value displays are separate vertical sections.

### Weekly remaining quota

The weekly quota section keeps its existing percentage, reset time, and progress
length. Its progress color communicates urgency:

- `remainingPercent >= 20`: green.
- `10 <= remainingPercent < 20`: yellow.
- `remainingPercent < 10`: red.
- Exactly `20%` is green; exactly `10%` is yellow.
- The color rule applies only to the weekly window
  (`durationMinutes == 10_080`). Other quota-window progress bars retain their
  existing system tint.

### Monthly API-equivalent value

The new section appears after the quota windows and before reset credits:

```text
本月 API 等价价值                         $13.25～$41.00
[ green minimum ][ yellow uncertainty ]--------------------
$0        Plus $20                                  Pro $200
低估 $13.25    高估 $41.00
估算区间跨过 Plus $20 · 未达到 Pro $200
本月 5.00M tokens · GPT-5.6 Sol · API 等价估算，并非实际账单
```

- The track is a linear `$0～$200` scale.
- The solid green segment runs from `$0` to the lower estimate.
- The green-to-yellow segment runs from the lower to the upper estimate.
- A red marker at `10%` represents Plus `$20`.
- A purple marker at the right edge represents Pro `$200`.
- If an estimate exceeds `$200`, the visual fill is clipped at the right edge,
  but the displayed dollar amount is not clipped.
- The value line is independent of quota percentages. A `31%` quota value never
  controls the length or color of the dollar-value line.

The benchmark status is calculated independently for Plus and Pro:

- Upper estimate below the benchmark: `未达到`.
- Lower estimate at or above the benchmark: `已达到`.
- Range crossing the benchmark: `可能达到`.

The two results are combined into one concise line, for example
`可能达到 Plus $20 · 未达到 Pro $200`.

## Data source and privacy boundary

Use the read-only Codex app-server method `account/usage/read`. The current
protocol returns an optional `dailyUsageBuckets` array whose rows contain a
date-only `startDate` and an `Int64` token count.

The feature must not:

- read Codex conversation/session logs;
- read browser cookies, credentials, authentication files, or the Codex state
  database;
- call a mutation method;
- send usage data to a new service; or
- attempt to reconstruct input, cached-input, or output tokens from private
  conversation content.

The existing outbound-method whitelist must be expanded only with
`account/usage/read`.

## Monthly token calculation

Introduce a small pure monthly-usage mapper. It receives daily buckets, the
current date, and a `Calendar` so month-boundary behavior is deterministic in
tests.

- Use the Mac's current calendar and time zone.
- Include buckets whose `startDate` falls from the first day of the current
  calendar month through the day before the next month.
- Treat `startDate` as a date-only value so parsing does not shift it across a
  day boundary.
- An empty array means zero tokens.
- A `null`/missing `dailyUsageBuckets` value means the monthly value is
  unavailable; it must not be displayed as `$0`.
- A malformed date, negative token count, or checked-sum overflow makes the
  monthly value unavailable rather than silently understating consumption.

The stored monthly value includes its month identifier, summed token count, and
fetch time. It is optional in `QuotaSnapshot` so older cache files remain
decodable.

## Estimation algorithm

The app cannot observe the model-specific split among regular input, cached
input, and output tokens. It therefore shows a scenario range instead of a
false precise amount.

Reference prices for GPT-5.6 Sol:

- Regular input: `$5.00 / 1M tokens`.
- Cached input: `$0.50 / 1M tokens`.
- Output: `$30.00 / 1M tokens`.

Lower scenario:

- 80% cached input, 15% regular input, 5% output.
- Blended rate:
  `0.80 × $0.50 + 0.15 × $5.00 + 0.05 × $30.00 = $2.65 / 1M`.

Upper scenario:

- 40% cached input, 40% regular input, 20% output.
- Blended rate:
  `0.40 × $0.50 + 0.40 × $5.00 + 0.20 × $30.00 = $8.20 / 1M`.

For monthly token count `T`:

```text
lowerUSD = T / 1,000,000 × 2.65
upperUSD = T / 1,000,000 × 8.20
```

Use `Decimal` for the calculation and round only for presentation. Dollar
amounts display with two decimal places. Token counts use a compact localized
format such as `5.00M tokens`.

The reference model, fixed scenario assumptions, Plus `$20`, and Pro `$200`
are bundled constants. The app performs no pricing-network request. The UI and
README must label the result as an estimate so future pricing drift is not
mistaken for a live bill.

Official references used for the fixed assumptions:

- GPT-5.6 Sol pricing:
  <https://developers.openai.com/api/docs/models/gpt-5.6-sol>
- ChatGPT Plus price context:
  <https://help.openai.com/en/articles/6950777-what-is-the-difference-between-the-free-and-paid-versions-of-chatgpt>
- ChatGPT Pro `$200` tier context:
  <https://help.openai.com/en/articles/9793128>

OpenAI also offers a Pro `$100` tier at the time of this design. It is
intentionally omitted from the track because the approved comparison is Plus
`$20` versus Pro `$200`; adding a third marker would broaden the requested UI.

## Architecture and component boundaries

### Wire protocol

- Add `account/usage/read` to the app-server method enum and audit whitelist.
- Add wire models for the usage response and daily buckets.
- Extend the existing app-server client with a typed read operation. Reuse the
  initialized stdio transport and existing timeout/retry/error behavior.
- Perform rate-limit and usage reads sequentially on the actor-owned transport;
  do not create two competing receive loops.

### Domain and mapping

- Add an optional, codable `MonthlyUsage` value to `QuotaSnapshot`.
- Keep rate-limit mapping and reset-credit mapping unchanged.
- Add pure helpers for monthly-bucket aggregation and API-equivalent estimation.
- Add a pure weekly-quota color-band helper so exact threshold behavior can be
  tested without inspecting SwiftUI internals.

### Refresh and cache flow

Every existing five-minute refresh performs:

1. Read rate limits. This remains the required primary operation.
2. Read account usage on the same initialized app-server connection.
3. Aggregate the current month and estimate the dollar range.
4. Publish and atomically cache one display snapshot.

Usage is auxiliary. If the usage read or aggregation fails while rate limits
succeed, publish the fresh rate-limit data with monthly usage unavailable and
show `本月使用数据暂不可用`. Do not hide quota windows, reset credits, or their
refresh time. The next normal refresh retries usage automatically.

If the primary rate-limit read fails, preserve the existing cache/stale behavior.
A cached snapshot that already contains monthly usage is displayed under the
same stale-state warning as the rest of that snapshot.

### SwiftUI presentation

- Keep the menu width at `330` points unless real-app rendering proves text is
  truncated; do not widen it preemptively.
- Render the value track with a small dedicated view/presentation model rather
  than embedding pricing arithmetic in `MenuBarContentView`.
- Use explicit accessibility labels for the quota state, estimate range, and
  Plus/Pro comparison. Do not rely on progress colors alone.
- Preserve the existing reset-credit, notification, launch-at-login, and footer
  behavior.

## Alternatives considered

### Selected: account usage plus a scenario range

This uses a read-only first-party app-server value, avoids private conversation
content, and makes uncertainty visible.

### Rejected: parse local Codex sessions

This might infer a more detailed token split, but it expands the privacy surface,
couples the app to private storage formats, and violates the approved privacy
boundary.

### Rejected: show one midpoint dollar amount

A single number looks more precise but conceals the unknown cached/input/output
mix. The range better represents the available evidence.

### Rejected: separate Plus and Pro value bars

Two benchmark bars make `$20` easier to read but would create three progress
lines in total and conflict with the approved two-line layout. One linear
`$0～$200` track keeps both benchmarks honest and comparable.

## Error and edge-case behavior

- Zero monthly tokens displays `$0.00～$0.00` and an empty value fill.
- `dailyUsageBuckets == nil` displays an unavailable message, not zero.
- Invalid usage data never reduces the estimate silently.
- Values above `$200` keep their full text amount while the fill remains within
  the track.
- Missing usage data never removes the primary quota display.
- Existing cache files without the new optional field continue to load.
- Cancellation during shutdown is rethrown and must not be converted into an
  auxiliary usage error.

## Testing and verification

Unit and contract tests cover:

- decoding `account/usage/read` responses with populated, empty, and null daily
  buckets;
- sending only the newly approved read method and matching the correct JSON-RPC
  response;
- sequential rate-limit and usage reads over one client transport;
- calendar-month inclusion, month/year boundaries, leap days, and injected time
  zones;
- null buckets, malformed dates, negative tokens, and sum overflow;
- exact estimates for zero, 1M, and 5M tokens;
- Plus and Pro statuses below, exactly at, and crossing each benchmark;
- value-track percentage calculation and clipping above `$200`;
- weekly color boundaries at `9%`, `10%`, `19%`, and `20%`, plus proof that a
  non-weekly window retains its existing tint;
- decoding an old cache file that omits monthly usage;
- usage failure preserving the primary quota display;
- source/UI contracts for the two independent progress lines and estimate
  disclaimer.

Before installation, run the complete test suite, release build, bundle
verification, and the existing outbound-method audit. Then inspect the real
menu-bar app to confirm the two tracks are vertically separated, all labels fit,
and the weekly `20%`/`10%` boundary colors match the specification.
