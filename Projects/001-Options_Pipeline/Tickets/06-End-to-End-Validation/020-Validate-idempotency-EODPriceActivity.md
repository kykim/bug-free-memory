# TICKET-020 · Validate idempotency: re-run `EODPriceActivity` for same date

**Task:** Write an integration test or manual validation script that:
1. Runs `EODPriceActivity` for a given `runDate`.
2. Records the `rowsUpserted` count.
3. Runs `EODPriceActivity` again for the same `runDate`.
4. Asserts that the second run's `rowsUpserted` count equals the first (all upserts, no errors from duplicate key violations).
5. Queries `eod_prices` directly and confirms no duplicate `(instrument_id, price_date)` rows.

**Acceptance criteria:** No unique constraint violation. Row count in `eod_prices` unchanged between run 1 and run 2.
