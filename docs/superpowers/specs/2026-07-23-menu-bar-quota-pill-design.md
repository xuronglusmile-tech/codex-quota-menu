# Menu Bar Quota Pill Design

## Summary

Replace the current gauge icon and compound `percentage · reset count` menu-bar
title with a compact macOS battery-style quota indicator. The left side is a
rounded pill whose fill level represents the weekly Codex quota remaining. The
right side shows the same percentage as text, for example `31%`.

Reset-credit count remains available in the popover and is removed from the
menu-bar label. This makes the always-visible status answer one question only:
how much weekly Codex quota remains.

## Goals

- Match the compact visual language of the macOS battery status item.
- Show weekly remaining quota directly in the menu bar without opening the app.
- Keep both a visual fill and an exact percentage.
- Reuse the approved weekly thresholds: green at 20% or above, yellow from 10%
  through 19%, and red below 10%.
- Preserve all existing quota reads, refresh behavior, notifications, monthly
  scenario estimates, and reset-credit rows.

## Non-goals

- Do not show reset-credit count in the menu bar.
- Do not combine the weekly quota with a secondary quota window.
- Do not change the popover's existing quota progress bars.
- Do not add click actions, settings, API calls, or new stored data.
- Do not imitate the battery terminal nub; the requested shape is a simple pill.

## Data selection

The pill uses the weekly rate-limit window (`durationMinutes == 10_080`) rather
than `mostConstrainedRemainingPercent`. This keeps the menu-bar value aligned
with the popover's `每周额度` row even when another window is more constrained.

The displayed percentage is the same clamped integer percentage used to size
the fill. Values below zero render as 0%; values above 100 render as 100%.

## Visual design

The menu-bar label is ordered left to right:

1. a rounded rectangular outline sized for the menu-bar cap height;
2. an inset fill whose width equals the weekly remaining fraction;
3. a short gap;
4. the numeric remaining percentage, such as `31%`.

The outline remains readable in light and dark menu-bar appearances. The fill
uses the existing status bands:

| Weekly remaining | Fill color |
| --- | --- |
| `20%...100%` | green |
| `10%...19%` | yellow |
| `0%...9%` | red |

The percentage uses the system menu-bar foreground color so it remains legible
and visually consistent with macOS. The pill is decorative; the combined
accessibility label states `每周剩余额度 31%`.

## State behavior

- Loading: show an empty neutral pill and `--`.
- Fresh data with a weekly window: show its fill, threshold color, and exact
  percentage.
- Stale cached data: show the last known fill and percentage, followed by `!`.
- Snapshot without a weekly window: show an empty neutral pill and `--`.
- Unavailable data: show an empty neutral pill and `不可用`.

The stale marker preserves the current warning convention without adding a
second icon.

## Architecture

Add a small pure presentation model that maps `QuotaDisplayState` to the menu
bar's percentage, fill fraction, status band, text, and accessibility label.
Keep weekly-window selection and clamping in this testable layer.

Add a dedicated SwiftUI label view that draws the pill and text. The app entry
point supplies the presentation derived from `QuotaStore.state`; no transport,
domain, or persistence code changes.

## Testing

Presentation tests cover:

- selecting the weekly window instead of the most constrained non-weekly
  window;
- 31% producing a 0.31 fill and green band;
- exact 20% remaining being green;
- 19% remaining being yellow;
- exact 10% remaining being yellow;
- 9% remaining being red;
- clamping out-of-range values;
- loading, stale, missing-weekly-window, and unavailable text behavior;
- absence of reset-credit count in the menu-bar label.

UI source-contract tests verify that the app uses the new dedicated label view
instead of the gauge SF Symbol. Run the full test suite, release build, bundle
verification, and real menu-bar inspection after installation.

## Rollout

Install through the existing atomic installer. Acceptance requires the menu bar
to show a pill plus weekly percentage at normal display scale in both light and
dark menu-bar appearances, while the popover continues to show reset credits
and all existing sections unchanged.
