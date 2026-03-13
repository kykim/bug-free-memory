# TICKET-015 · Implement `DailyPipelineWorkflow`

**File:** `Sources/bug-free-memory/Workflows/DailyPipelineWorkflow.swift`

**Task:** Implement the top-level Temporal workflow that orchestrates all five activities.

**Depends on:** TICKET-010, TICKET-011, TICKET-012, TICKET-013, TICKET-014.

**Logic:**
1. Check `MarketCalendar.isHoliday(runDate)`. If true: log, execute `RunLogActivity` with `status: .skipped`, return.
2. Execute `PortfolioActivity`. Catch any error → append to `errorMessages`, set `portfolioResult = nil`, continue.
3. Execute `EODPriceActivity`. Catch → append error, `eodResult = nil`, continue.
4. Execute `OptionEODPriceActivity`. Catch → append error, `optionEODResult = nil`, continue.
5. If `optionEODResult?.rowsUpserted ?? 0 > 0`: execute `PricingActivity`. Catch → append error, `pricingResult = nil`. Else: append `"PricingActivity skipped: no option EOD data"`.
6. Determine `status` via `RunStatus.determine(...)`.
7. Always execute `RunLogActivity` with full `RunLogInput`.

**Acceptance criteria:**
- Workflow short-circuits correctly on market holiday (only `RunLogActivity` executes).
- A `PortfolioActivity` failure does not prevent `EODPriceActivity` or `OptionEODPriceActivity` from running.
- `PricingActivity` is skipped when `optionEODResult` is `nil` or has `rowsUpserted == 0`.
- `RunLogActivity` always executes regardless of upstream failures.
- `startedAt` is captured before any activities execute.
