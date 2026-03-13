# TICKET-019 · Smoke test: `YieldCurve.interpolate` unit tests

**Task:** Write unit tests for `YieldCurve.interpolate` covering all branches.

**Test cases:**
- Empty curve → returns `0.05`.
- Single point at `tenorYears: 1.0, rate: 0.04` → `interpolate(0.5)` returns `0.04`.
- Two points: `(1.0, 0.04)` and `(2.0, 0.06)` → `interpolate(1.5)` returns `0.05`.
- `T < 1.0` (below shortest) → returns `0.04`.
- `T > 2.0` (above longest) → returns `0.06`.

**Acceptance criteria:** All five cases pass.
