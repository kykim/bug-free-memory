# TICKET-021 · Validate idempotency: re-run `PricingActivity` for same date

**Task:** Same pattern as TICKET-020 but for `PricingActivity` and `theoretical_option_eod_prices`.

**Acceptance criteria:**
- No unique constraint violation on `(instrument_id, price_date, model)`.
- Exactly 3 rows per contract in `theoretical_option_eod_prices` after both runs.
- Prices from run 2 match prices from run 1 (deterministic output).
