# TICKET-006 · Implement `YieldCurve`

**File:** `Sources/bug-free-memory/Models/YieldCurve.swift`

**Task:** Implement the yield curve value type used for risk-free rate interpolation.

```swift
struct YieldCurve: Sendable {
    struct Point: Sendable { let tenorYears: Double; let continuousRate: Double }
    let points: [Point]   // sorted ascending by tenorYears
    let observationDate: Date
    static func load(db: Database, runDate: Date) async throws -> YieldCurve
    func interpolate(timeToExpiry: Double) -> Double
}
```

**`load` logic:**
1. Find `MAX(observation_date)` from `fred_yields WHERE observation_date <= runDate` using raw SQL.
2. Query `FREDYield` rows for that date, sorted ascending by `tenor_years`.
3. Return `YieldCurve` with those points. If no rows, return curve with empty points array.

**`interpolate` logic:**
- Empty points → return `0.05` as fallback.
- Single point → return that rate.
- `T <= first tenor` → return first rate (flat extrapolation).
- `T >= last tenor` → return last rate (flat extrapolation).
- Otherwise → linear interpolation between bracketing tenors.

**Acceptance criteria:**
- `interpolate(timeToExpiry: 0.0)` returns first tenor's rate.
- `interpolate(timeToExpiry: 100.0)` returns last tenor's rate.
- Interpolation between two known tenors produces the correct linear result.
- `load` queries for most recent observation date on or before `runDate`, not strictly equal.
- File compiles with `import Fluent`.
