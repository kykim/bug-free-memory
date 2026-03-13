# TICKET-011 · Implement `EODPriceActivity`

**File:** `Sources/bug-free-memory/Activities/EODPriceActivity.swift`

**Task:** Implement the Temporal activity that fetches EOD prices for all active instruments in `equities` or `indexes` and upserts them into `eod_prices`.

**Depends on:** TICKET-003.

**Logic:**
1. Query all `Instrument` rows where `is_active == true` and a matching row exists in `equities` OR `indexes` (use two separate `.first()` checks per instrument, or a raw SQL EXISTS query).
2. For each instrument: call `tiingoClient.fetchEODPrice(ticker:date:)`. On `nil` response: append ticker to `failedTickers`, log warning, continue. On `TiingoError.authFailure`: rethrow (Temporal retry). On any other error: append ticker to `failedTickers`, log error, continue.
3. On success: call `upsertEODPrice(...)` using raw SQL `ON CONFLICT (instrument_id, price_date) DO UPDATE`. Fields: `open`, `high`, `low`, `close`, `adj_close`, `volume`, `source = "tiingo"`.
4. Return `EODPriceResult`.

**Critical:** Do NOT include `mid` anywhere — that column only exists on `option_eod_prices`, but note this constraint pattern for consistency.

**Retry policy:** 3 attempts, 30s initial, backoff 2.0, schedule-to-close 300s.

**Acceptance criteria:**
- A `nil` Tiingo response for one ticker does not abort the loop.
- `TiingoError.authFailure` propagates as a throw.
- Upsert SQL uses `ON CONFLICT (instrument_id, price_date) DO UPDATE`.
- `source` field is always written as `"tiingo"`.
