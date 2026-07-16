# Dynamic Sol API Scenario Scale Design

## Summary

The monthly token aggregation is correct, but the current presentation gives a
stronger conclusion than the available data supports. `account/usage/read`
returns aggregate daily token activity without a model breakdown or separate
regular-input, cached-input, and output counts. The app currently applies two
fixed GPT-5.6 Sol token-mix assumptions, calls them a low/high value range, and
compares the result directly with Plus `$20` and Pro `$200` subscription
prices. This makes a hypothetical API-cost scenario look like a measured
subscription value.

Replace that comparison with a model-specific scenario display. Keep the real
monthly token total and the existing fixed Sol price assumptions, remove every
subscription-price marker and verdict, and scale the dollar track dynamically
so large values remain visually meaningful.

## Evidence and problem statement

The live read on 2026-07-16 returned 15 unique July buckets totaling
`491,735,161` tokens. The monthly mapper included each date once and matched the
server total, so duplicate summation is not the cause of the large value.

The existing blended rates are:

- cached-heavy scenario: `$2.65 / 1M` tokens, based on 80% cached input, 15%
  regular input, and 5% output;
- output-heavier scenario: `$8.20 / 1M` tokens, based on 40% cached input, 40%
  regular input, and 20% output.

Those are fixed GPT-5.6 Sol scenarios, not statistically calibrated bounds.
The usage response cannot establish that all tokens used Sol, that the assumed
token mixes match the account, or that the resulting amount is comparable to a
ChatGPT subscription price. The current `$0–$250` track also saturates for
large monthly values and stops communicating magnitude.

## Goals

- Preserve the source-backed current-calendar-month token total.
- Preserve the two existing GPT-5.6 Sol standard-API price scenarios.
- Name the scenarios by their assumptions rather than `low` and `high` value.
- Remove Plus and Pro price markers and every `reached`, `crossing`, or `below`
  subscription verdict.
- Give the scenario track a deterministic dynamic maximum that remains useful
  for both small and large amounts.
- State explicitly that the values are hypothetical API scenarios, not an
  invoice, savings measurement, or subscription valuation.
- Keep the quota, reset-credit, refresh, privacy, and cache behavior unchanged.

## Non-goals

- Do not infer the real input/cached-input/output split.
- Do not infer which model produced each token.
- Do not add network pricing lookups or change the bundled Sol rates.
- Do not calculate a monthly subscription-utilization score; the app does not
  yet retain enough historical weekly-window data for that metric.
- Do not change the `$20` Plus or `$200` Pro constants elsewhere if they are
  absent after this feature is removed; no replacement subscription marker is
  introduced.
- Do not change `account/usage/read`, monthly aggregation, cache shape, or the
  five-minute refresh interval.

## Domain and presentation model

Rename API-equivalent values so their semantics are explicit:

- `cachedHeavyUSD`: scenario using 80% cached input, 15% regular input, and 5%
  output;
- `outputHeavyUSD`: scenario using 40% cached input, 40% regular input, and 20%
  output.

The pricing arithmetic remains:

```text
cachedHeavyUSD = monthlyTokens / 1,000,000 × 2.65
outputHeavyUSD = monthlyTokens / 1,000,000 × 8.20
```

Remove `BenchmarkPosition`, benchmark constants, benchmark fractions, and
status-verdict generation. The presentation model exposes the two formatted
scenario strings, the combined range string, the token string, the dynamic
track maximum text, and the two track fractions.

## Dynamic track scale

The track maximum is the smallest nice number greater than or equal to the
output-heavier scenario. Nice numbers use the sequence `1`, `2`, `5`, `10`
times a power of ten. The minimum maximum is `$50`, which keeps the zero and
small-usage states stable.

Examples:

| Output-heavier scenario | Track maximum |
| ---: | ---: |
| `$0.00` | `$50` |
| `$41.00` | `$50` |
| `$50.00` | `$50` |
| `$51.00` | `$100` |
| `$820.00` | `$1,000` |
| `$4,032.23` | `$5,000` |

The two fractions are calculated against this maximum and clamped to `0...1`.
The track shows three labels: `$0`, the formatted midpoint, and the formatted
maximum. It contains no subscription-plan markers. Dollar labels omit decimal
places for whole-number scale values and use US grouping separators when
needed.

## UI and copy

Change the section title from `本月 API 等价价值` to `Sol API 假设场景`.

The visual order is:

1. title and combined scenario amount;
2. dynamic two-color scenario track;
3. legend values:
   - `缓存较多情景 $…` in green;
   - `输出较多情景 $…` in yellow;
4. concise assumption line: `固定构成：80/15/5 · 40/40/20`;
5. monthly token total and `GPT-5.6 Sol 标准 API 价格`;
6. disclaimer: `情景估算，并非实际账单或订阅价值`.

Remove the old yellow subscription status line. Remove `Plus $20`, `Pro $200`,
and `$250` from the value view. The menu remains 330 points wide and the value
section remains between quota windows and reset credits.

The accessibility label combines the title, both named scenario values, token
total, fixed-mix note, and disclaimer. The decorative track remains hidden from
accessibility.

## Error and unavailable behavior

The existing source behavior remains unchanged:

- missing or null daily buckets display `本月使用数据暂不可用`;
- malformed dates, negative token counts, or sum overflow make monthly usage
  unavailable;
- a usage read failure does not remove quota-window or reset-credit data;
- zero tokens display `$0.00～$0.00` with empty fills on a `$0–$50` track.

## Documentation

Update the README to describe the two fixed Sol scenarios as hypothetical API
costs. It must state that the result is not a bill, savings amount, or valuation
of Plus or Pro. Remove wording that suggests the track measures whether the
subscription price has been recovered.

## Testing

Pure presentation tests cover:

- five million tokens producing `$13.25～$41.00` on a `$0–$50` track;
- zero tokens producing empty fills and a `$50` maximum;
- exact nice-boundary behavior at `$50`;
- rollover from `$51` to a `$100` maximum;
- a large current-scale value using a `$5,000` maximum without clipping text;
- midpoint and maximum formatting with grouping separators;
- absence of subscription verdict fields and benchmark fractions.

UI source-contract tests require the new title, scenario labels, fixed-mix
copy, and disclaimer. They reject `Plus $20`, `Pro $200`, the old subscription
status wording, and a fixed `$250` endpoint in the monthly value view.

Run the full test suite, release build, signed-bundle verification, outbound
method audit, atomic installation, and real menu-bar inspection. Real-runtime
acceptance requires a non-saturated dynamic track at the current large usage,
no subscription markers or verdict, and fully visible disclaimer text.

## Compatibility and rollout

This is a presentation-only semantic correction. The cache remains compatible,
the app-server whitelist remains unchanged, and existing monthly totals continue
to decode. Install through the existing atomic installer and retain the current
rollback guarantees.
