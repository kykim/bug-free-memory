# TICKET-005 · Implement `MarketCalendar`

**File:** `Sources/bug-free-memory/Extensions/MarketCalendar.swift`

**Task:** Implement the US market holiday calendar for 2026.

```swift
enum MarketCalendar {
    static func isHoliday(_ date: Date) -> Bool
    static func isTradingDay(_ date: Date) -> Bool
}
```

**2026 holidays to include:**
`20260101` (New Year's), `20260119` (MLK), `20260216` (Presidents'), `20260403` (Good Friday), `20260525` (Memorial Day), `20260703` (Independence Day observed), `20260907` (Labor Day), `20261126` (Thanksgiving), `20261225` (Christmas).

**Acceptance criteria:**
- `isHoliday` returns `true` for all nine dates above.
- `isHoliday` returns `false` for `20260313` (a normal Friday).
- `isTradingDay` returns `false` for weekends and holidays.
- `isTradingDay` returns `true` for `20260313`.
- Uses `DateFormatter` with `yyyyMMdd` format and `America/New_York` timezone.
