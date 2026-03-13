# TICKET-012 · Implement `OptionEODPriceActivity`

**File:** `Sources/bug-free-memory/Activities/OptionEODPriceActivity.swift`

**Task:** Implement the Temporal activity that fetches EOD prices for all non-expired option contracts from Schwab and upserts them into `option_eod_prices`.

**Depends on:** TICKET-003, TICKET-006, TICKET-009.

**Logic:**
1. Call `schwabClient.refreshTokenIfNeeded(db:)`.
2. Query `option_contracts WHERE expiration_date >= startOfDay(runDate)`.
3. Load `YieldCurve.load(db:runDate:)` once before the loop.
4. For each contract: call `schwabClient.fetchOptionEODPrice(osiSymbol:)`. On `nil`: append `SkippedContract(reason: "no_quote")`, log warning, continue. On `SchwabError.authFailure`: rethrow. On other error: append `SkippedContract(reason: "fetch_error")`, log error, continue.
5. On success: interpolate `riskFreeRate = yieldCurve.interpolate(contract.timeToExpiry(from: runDate))`. Upsert into `option_eod_prices` using raw SQL.
6. Return `OptionEODResult`.

**Critical upsert constraint:** Never write the `mid` column — it is `GENERATED ALWAYS AS ((bid + ask) / 2) STORED`. Including it in the INSERT will throw a Postgres runtime error.

**Columns to write:** `bid`, `ask`, `last`, `settlement_price`, `volume`, `open_interest`, `implied_volatility`, `delta`, `gamma`, `theta`, `vega`, `rho`, `underlying_price`, `risk_free_rate`, `source`.

**Retry policy:** 3 attempts, 30s initial, backoff 2.0, schedule-to-close 600s.

**Acceptance criteria:**
- `mid` does not appear anywhere in the INSERT or DO UPDATE clause.
- `nil` quote returns `SkippedContract(reason: "no_quote")` without throwing.
- `SchwabError.authFailure` propagates as a throw.
- `riskFreeRate` is interpolated per-contract from the pre-loaded yield curve.
