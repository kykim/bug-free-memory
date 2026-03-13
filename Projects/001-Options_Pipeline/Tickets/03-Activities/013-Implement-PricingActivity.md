# TICKET-013 · Implement `PricingActivity`

**File:** `Sources/bug-free-memory/Activities/PricingActivity.swift`

**Task:** Implement the Temporal activity that prices all non-expired contracts using Black-Scholes, Binomial CRR, and Monte Carlo LSM and upserts results into `theoretical_option_eod_prices`.

**Depends on:** TICKET-003, TICKET-006.

**Logic:**
1. Load `YieldCurve`. If `points.isEmpty`, throw `PricingError.noFREDRatesAvailable(runDate:)`.
2. Query `option_contracts WHERE expiration_date >= today` with `.with(\.$underlying)`.
3. Run `withThrowingTaskGroup` over contracts. Each task calls `priceContract(contract:yieldCurve:runDate:)`.
4. `priceContract`:
   a. Fetch today's `OptionEODPrice` row. If missing → return `.failure(reason: "no_eod_price_today")`.
   b. Fetch last 31 days of `EODPrice` history for underlying, sorted ascending. If fewer than 2 rows → `.failure(reason: "insufficient_history")`.
   c. Interpolate `r` from `yieldCurve`.
   d. Call `contract.blackScholesPrice(...)`, `contract.binomialPrice(...)`, `contract.monteCarloPrice(...)`. Pass `currentPrice: history.last!`, `priceHistory: history`, `riskFreeRate: r`.
   e. For each non-nil result: build `TheoreticalOptionEODPrice` using `.from(result:...)` factory. Set `impliedVolatility` from `optionEOD.impliedVolatility`. Upsert on `(instrument_id, price_date, model)`.
   f. If all three pricers return `nil` → return `.failure(reason: "all_pricers_returned_nil")`.
   g. Return `.success(rowsUpserted: n)`.
5. Aggregate all outcomes into `PricingResult`.

**Upsert conflict target:** `(instrument_id, price_date, model)`.

**`PricingError`:**
```swift
enum PricingError: Error { case noFREDRatesAvailable(runDate: Date) }
```

**Retry policy:** 2 attempts, 10s initial, backoff 1.5, schedule-to-close 1800s.

**Acceptance criteria:**
- Empty yield curve throws `PricingError.noFREDRatesAvailable` before any contracts are processed.
- Missing `option_eod_prices` row for today returns `FailedContract(reason: "no_eod_price_today")`, not a throw.
- Each contract task is independent — one failure does not cancel other tasks in the group.
- Up to 3 upsert rows per successful contract (one per model).
- `YieldCurve` is loaded once and passed to all concurrent tasks (not re-queried per contract).
