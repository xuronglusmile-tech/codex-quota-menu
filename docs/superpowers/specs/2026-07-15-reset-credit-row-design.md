# Reset Credit Row Design

## Goal

Make the reset-credit section concise and immediately scannable. Replace the
backend-provided `Full reset` title and verbose English description with a
Chinese ordinal plus its expiration time.

## Approved presentation

Each available reset credit is shown on one row:

```text
第一次                         到期：2026年7月18日 8:42
第二次                         到期：2026年7月27日 8:17
```

- Number rows in their existing expiration order using Chinese ordinals:
  `第一次`, `第二次`, `第三次`, and so on.
- Show `到期：<localized date and time>` on the right.
- If a credit has no expiration, show `到期：不过期`.
- Do not render the backend title or description anywhere in the row.
- Keep the existing orange `即将到期` indicator beneath the right-side time
  when the expiration is within the next 24 hours.

## Implementation boundary

- Add a small pure presentation helper for Chinese ordinal labels so the
  formatting can be tested without inspecting SwiftUI internals.
- Pass the enumerated row index into `resetCreditRow`.
- Do not change response mapping, cache shape, notification scheduling, quota
  counts, expiration ordering, privacy behavior, or backend data retention.

## Verification

- Unit tests cover the first several Chinese ordinal labels and a safe fallback
  for larger indices.
- A source/UI contract test proves the row uses the ordinal and `到期：` label
  and no longer renders `credit.title`, `credit.detail`, or `Full reset`.
- Run the complete test suite, release build, bundle verification, and reinstall
  the verified app after the code review is clean.
