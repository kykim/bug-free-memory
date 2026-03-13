# Engineering Requirements Document (Mid-Level)
## Equity Index Options Data Pipeline & Pricer
**Version 1.0 | March 2026 | Confidential**

---

## 1. Overview

This document describes the mid-level engineering design for the automated daily options data pipeline. It extends the high-level ERD with detailed data flows, error handling behaviour, implementation notes, and expanded interfaces for each component.

The system is implemented in Swift using Vapor, Fluent ORM, and the Apple Swift Temporal SDK. All components run locally alongside the existing Vapor application.

---

## 2. System Architecture

### 2.1 Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Local Machine                        │
│                                                         │
│  ┌─────────────┐    ┌──────────────────────────────┐   │
│  │  Temporal   │    │        Vapor App              │   │
│  │  Server     │◄──►│  (existing, ClerkVapor auth)  │   │
│  └──────┬──────┘    └──────────────────────────────┘   │
│         │                                               │
│  ┌──────▼──────────────────────────────────────┐        │
│  │           Temporal Worker (Swift)            │        │
│  │                                              │        │
│  │  DailyPipelineWorkflow                       │        │
│  │    ├── PortfolioActivity                     │        │
│  │    ├── EODPriceActivity                      │        │
│  │    ├── OptionEODPriceActivity                │        │
│  │    ├── PricingActivity                       │        │
│  │    └── RunLogActivity                        │        │
│  └──────────────────┬───────────────────────────┘        │
│                     │                                    │
│  ┌──────────────────▼───────────────────────────┐        │
│  │              PostgreSQL                       │        │
│  │  (instruments, equities, indexes,             │        │
│  │   eod_prices, option_contracts,               │        │
│  │   option_eod_prices,                          │        │
│  │   theoretical_option_eod_prices,              │        │
│  │   fred_yields, oauth_tokens, job_runs)        │        │
│  └───────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────┘

External APIs:
  - Schwab Developer API  (OAuth 2.0 — existing client)
  - Tiingo REST API       (existing client)
  - CBOE DataShop         (optional, if free tier available)
```

### 2.2 File Structure

New files to be created under `Sources/bug-free-memory/`:

```
Sources/bug-free-memory/
├── Workflows/
│   └── DailyPipelineWorkflow.swift
├── Activities/
│   ├── PortfolioActivity.swift
│   ├── EODPriceActivity.swift
│   ├── OptionEODPriceActivity.swift
│   ├── PricingActivity.swift
│   └── RunLogActivity.swift
├── Models/
│   ├── JobRun.swift                       (new)
│   ├── FilteredPositionSet.swift          (new)
│   ├── EODPriceResult.swift               (new)
│   ├── OptionEODResult.swift              (new)
│   ├── PricingResult.swift                (new)
│   ├── RunLogInput.swift                  (new)
│   └── YieldCurve.swift                   (new)
├── Migrations/
│   └── CreateJobRuns.swift                (new)
└── Extensions/
    ├── SchwabClient+Portfolio.swift        (extends existing SchwabClient)
    ├── SchwabClient+OptionQuote.swift      (extends existing SchwabClient)
    ├── OSIParser.swift                     (new)
    ├── OptionContractRegistrar.swift       (new)
    └── MarketCalendar.swift                (new)
```

### 2.3 Key Design Principles

- **Temporal owns orchestration.** Scheduling, retries, and failure isolation are delegated entirely to Temporal. No Vapor scheduled jobs.
- **Database is the source of truth for scope.** Which instruments, options, and contracts are processed is determined entirely by querying existing tables — not by hardcoded symbols or runtime config.
- **All writes are upserts.** Every database write uses `ON CONFLICT DO UPDATE` to guarantee idempotency. Re-running the workflow for the same date produces no duplicates.
- **Existing code is wired, not rewritten.** The Schwab client, Tiingo client, FRED interpolation, and all three pricers already exist. This pipeline wires them together in a defined execution order.

### 2.4 Data Flow Overview

```
Schwab API
  │
  ▼
[PortfolioActivity]
  │  Reads:   Schwab positions
  │  Queries: instruments, equities (filter)
  │  Writes:  instruments (new option rows)
  │           option_contracts (new contract rows)
  │  Outputs: FilteredPositionSet
  │
  ├──────────────────────────────────────┐
  ▼                                      ▼
[EODPriceActivity]              [OptionEODPriceActivity]
  │  Reads:   Tiingo API           │  Reads:   Schwab API
  │  Queries: instruments,         │  Queries: option_contracts
  │           equities, indexes    │           (non-expired)
  │  Writes:  eod_prices           │  Writes:  option_eod_prices
  │  Outputs: EODPriceResult       │  Outputs: OptionEODResult
  │                                │
  └──────────────┬─────────────────┘
                 ▼
         [PricingActivity]
           │  Reads:   eod_prices (history)
           │           option_eod_prices (IV)
           │           fred_yields (rate curve)
           │           option_contracts (non-expired)
           │  Writes:  theoretical_option_eod_prices
           │  Outputs: PricingResult
           │
           ▼
     [RunLogActivity]
           │  Reads:   all activity outputs
           │  Writes:  job_runs
```

> **Note:** `EODPriceActivity` and `OptionEODPriceActivity` are logically independent and can run concurrently in a future optimisation. In v1.0 they run sequentially within the workflow.

---

## 3. Temporal Workflow Design

### 3.1 Workflow: `DailyPipelineWorkflow`

**Workflow ID pattern:** `daily-pipeline-YYYYMMDD`

**Schedule:** Temporal cron schedule: `0 16 * * 1-5` (4:00 PM ET, weekdays). Timezone: `America/New_York`.

**Early-exit condition:** At workflow start, check whether the run date is a US market holiday using the configured holiday list (`CFG-02`). If so, log `"Skipping: market holiday"` and return a zero-count `RunLogInput` with status `"skipped"`. No activities are executed.

**Token refresh:** Before executing `PortfolioActivity` or `OptionEODPriceActivity`, check `OAuthToken.isExpired(buffer: 60)`. If expired, refresh via the existing Schwab token refresh flow. This check occurs inside each activity, not at the workflow level.

**Activity execution order:**

```
DailyPipelineWorkflow
  │
  ├─ 1. PortfolioActivity
  │       └─ outputs: FilteredPositionSet
  │              (equityInstrumentIDs, optionInstrumentIDs,
  │               newContractsRegistered, droppedPositions, runDate)
  │
  ├─ 2. EODPriceActivity          (no dependency on FilteredPositionSet — runs independently)
  │       └─ outputs: EODPriceResult (rowsUpserted, instrumentsFetched, failedTickers)
  │
  ├─ 3. OptionEODPriceActivity    (no dependency on FilteredPositionSet — runs against DB)
  │       └─ outputs: OptionEODResult (contractsProcessed, rowsUpserted, skippedContracts)
  │
  ├─ 4. PricingActivity           (depends on OptionEODResult being non-zero)
  │       └─ outputs: PricingResult (contractsPriced, rowsUpserted, failedContracts)
  │
  └─ 5. RunLogActivity            (always runs — collects all results, writes job_runs)
```

**Workflow-level failure handling:**

| Scenario | Behaviour |
|----------|-----------|
| `PortfolioActivity` fails | Log error. Continue to EODPriceActivity and OptionEODPriceActivity. Skip PricingActivity only if OptionEODResult is empty. |
| `EODPriceActivity` fails | Log error. Continue remaining activities. EOD prices for this date will be missing but do not block pricing (pricing uses historical prices). |
| `OptionEODPriceActivity` fails | Log error. Skip `PricingActivity`. Pricing requires fresh option EOD data. |
| `PricingActivity` fails | Log error. Proceed to `RunLogActivity` with partial results. |
| `RunLogActivity` fails | Temporal retries up to 5 times. If all retries fail, the run outcome is lost but no data is corrupted. |

### 3.2 Activity Retry Policies

| Activity | Max Attempts | Initial Interval | Backoff Coefficient | Notes |
|----------|-------------|-----------------|---------------------|-------|
| PortfolioActivity | 3 | 30s | 2.0 | Schwab API rate limits may cause transient failures |
| EODPriceActivity | 3 | 30s | 2.0 | Tiingo occasionally returns 429s |
| OptionEODPriceActivity | 3 | 30s | 2.0 | Schwab API rate limits |
| PricingActivity | 2 | 10s | 1.5 | Failures are likely logic errors, not transient |
| RunLogActivity | 5 | 5s | 1.5 | Must be highly reliable |

### 3.3 Workflow Status Determination

`RunLogActivity` sets `status` on the `job_runs` record as follows:

- `"success"` — all four activities completed with no errors
- `"partial"` — one or more activities completed but at least one failed or skipped
- `"failed"` — `PortfolioActivity` and `OptionEODPriceActivity` both failed (no useful output produced)
- `"skipped"` — market holiday early-exit

---

## 4. Activity Design

### 4.1 `PortfolioActivity`

**Responsibility:** Download Schwab portfolio positions, apply two-pass filter, register any new option contracts.

**Interface:**
```swift
struct FilteredPositionSet: Codable {
    let equityInstrumentIDs: [UUID]
    let optionInstrumentIDs: [UUID]
    let newContractsRegistered: Int
    let droppedPositions: [DroppedPosition]
    let runDate: Date
}

struct DroppedPosition: Codable {
    let ticker: String
    let reason: String   // "not_in_equities" | "underlying_not_in_equities" | "unsupported_asset_type"
}

func portfolioActivity(db: Database, schwabClient: SchwabClient) async throws -> FilteredPositionSet
```

**Detailed logic:**

```
1. Call schwabClient.fetchPortfolioPositions()
   → returns [SchwabPosition]

2. Partition positions by assetType:
   - .equity   → equityPositions
   - .option   → optionPositions
   - other     → dropped immediately (reason: "unsupported_asset_type")

3. Equity filter:
   for each position in equityPositions:
     query: SELECT i.id FROM instruments i
            JOIN equities e ON e.instrument_id = i.id
            WHERE i.ticker = position.ticker
              AND i.instrument_type = 'equity'
              AND i.is_active = true
     if found  → append instrument.id to equityInstrumentIDs
     if not    → append DroppedPosition(ticker, reason: "not_in_equities")

4. Option filter:
   for each position in optionPositions:
     osi = parseOSISymbol(position.osiSymbol)
     query: SELECT i.id FROM instruments i
            JOIN equities e ON e.instrument_id = i.id
            WHERE i.ticker = osi.underlyingTicker
              AND i.instrument_type = 'equity'
              AND i.is_active = true
     if not found → append DroppedPosition(reason: "underlying_not_in_equities"), continue
     if found:
       check: SELECT id FROM option_contracts WHERE osi_symbol = position.osiSymbol
       if exists → append existing instrument_id to optionInstrumentIDs
       if not    → registerNewOptionContract(osi, underlyingInstrumentID, db)
                   append new instrument_id to optionInstrumentIDs
                   increment newContractsRegistered

5. Return FilteredPositionSet
```

**Error handling:**
- A failure to fetch positions from Schwab throws and triggers Temporal retry.
- A failure to register a single new option contract logs a warning and continues — do not fail the entire activity for one bad contract.
- OSI symbol parse failures are treated as drops with reason `"osi_parse_error"`.

---

### 4.2 `EODPriceActivity`

**Responsibility:** Fetch and persist EOD closing prices for all active instruments in `equities` and `indexes` tables. Runs independently of portfolio filter.

**Interface:**
```swift
struct EODPriceResult: Codable {
    let rowsUpserted: Int
    let instrumentsFetched: Int
    let failedTickers: [String]   // tickers where Tiingo returned no data or an error
    let source: String
}

func eodPriceActivity(db: Database, tiingoClient: TiingoClient) async throws -> EODPriceResult
```

**Detailed logic:**

```
1. Build eligible instrument list:
   SELECT i.id, i.ticker FROM instruments i
   WHERE i.is_active = true
     AND (
       EXISTS (SELECT 1 FROM equities e WHERE e.instrument_id = i.id)
       OR
       EXISTS (SELECT 1 FROM indexes ix WHERE ix.instrument_id = i.id)
     )

2. For each instrument:
   a. Call tiingoClient.fetchEODPrice(ticker: instrument.ticker, date: runDate)
   b. If successful:
      - Build EODPrice model
      - Upsert on (instrument_id, price_date)
      - Increment rowsUpserted
   c. If Tiingo returns 404 or no data for this date:
      - Append ticker to failedTickers
      - Log warning — do not throw
   d. If Tiingo returns a network/5xx error:
      - Append ticker to failedTickers
      - Log error — do not throw; allow remaining instruments to proceed

3. Return EODPriceResult
```

**Error handling:**
- Per-instrument failures are captured in `failedTickers` and do not abort the activity.
- If Tiingo returns a global error (e.g. auth failure, sustained 5xx), throw — allow Temporal to retry the whole activity.
- Log duration and row count on completion.

---

### 4.3 `OptionEODPriceActivity`

**Responsibility:** Fetch and persist EOD prices for all non-expired option contracts from Schwab.

**Interface:**
```swift
struct OptionEODResult: Codable {
    let contractsProcessed: Int
    let rowsUpserted: Int
    let skippedContracts: [SkippedContract]
}

struct SkippedContract: Codable {
    let instrumentID: UUID
    let osiSymbol: String?
    let reason: String   // "no_quote" | "fetch_error" | "expired"
}

func optionEODPriceActivity(db: Database, schwabClient: SchwabClient) async throws -> OptionEODResult
```

**Detailed logic:**

```
1. Query eligible contracts:
   SELECT oc.instrument_id, oc.osi_symbol, oc.underlying_id,
          oc.strike_price, oc.expiration_date, oc.option_type
   FROM option_contracts oc
   WHERE oc.expiration_date >= today

2. For each contract:
   a. Call schwabClient.fetchOptionEODPrice(osiSymbol: contract.osiSymbol)
   b. If quote returned:
      - Build OptionEODPrice model from SchwabOptionQuote
      - Set risk_free_rate from today's interpolated FRED rate
        (use contract's timeToExpiry for tenor matching)
      - Upsert on (instrument_id, price_date)
      - Do NOT write mid — generated column
      - Increment rowsUpserted
   c. If Schwab returns no quote (nil):
      - Append SkippedContract(reason: "no_quote")
      - Log warning — illiquid or delisted contract
   d. If Schwab returns a fetch error:
      - Append SkippedContract(reason: "fetch_error")
      - Log error — do not throw; continue to next contract

3. Return OptionEODResult
```

**Error handling:**
- Per-contract failures are captured in `skippedContracts` and do not abort the activity.
- If Schwab returns an auth error or sustained failure, throw — allow Temporal to retry.
- `PricingActivity` will skip contracts that have no `option_eod_prices` row for today.

---

### 4.4 `PricingActivity`

**Responsibility:** Run Black-Scholes, Binomial CRR, and Monte Carlo LSM over each non-expired contract and persist results.

**Interface:**
```swift
struct PricingResult: Codable {
    let contractsPriced: Int
    let rowsUpserted: Int          // contractsPriced × 3 (one per model)
    let failedContracts: [FailedContract]
}

struct FailedContract: Codable {
    let instrumentID: UUID
    let reason: String   // "no_eod_price_today" | "insufficient_history"
                         // | "pricing_returned_nil" | "no_fred_rate"
}

func pricingActivity(db: Database) async throws -> PricingResult
```

**Detailed logic:**

```
1. Query eligible contracts:
   SELECT oc.* FROM option_contracts oc
   WHERE oc.expiration_date >= today

2. For each contract (run concurrently via withTaskGroup):

   a. Fetch today's option EOD price:
      SELECT * FROM option_eod_prices
      WHERE instrument_id = contract.instrument_id
        AND price_date = today
      If missing → FailedContract(reason: "no_eod_price_today"), skip

   b. Fetch underlying EOD price history (last 31 days):
      SELECT * FROM eod_prices
      WHERE instrument_id = contract.underlying_id
        AND price_date >= today - 31 days
      ORDER BY price_date ASC
      If fewer than 2 rows → FailedContract(reason: "insufficient_history"), skip

   c. Interpolate risk-free rate:
      interpolateRate(timeToExpiry: contract.timeToExpiry(), db: db)
      If no fred_yields for today → FailedContract(reason: "no_fred_rate"), skip

   d. Run pricers:
      let currentPrice = priceHistory.last!
      let bs  = contract.blackScholesPrice(currentPrice:, priceHistory:, riskFreeRate: r)
      let bin = contract.binomialPrice(currentPrice:, priceHistory:, riskFreeRate: r)
      let mc  = contract.monteCarloPrice(currentPrice:, priceHistory:, riskFreeRate: r)

      If any pricer returns nil → log warning, record partial failure, continue with non-nil results

   e. Build TheoreticalOptionEODPrice records using factory helpers:
      let bsRecord  = TheoreticalOptionEODPrice.from(result: bs!,  ..., pricingModel: .blackScholes)
      let binRecord = TheoreticalOptionEODPrice.from(result: bin!, ..., pricingModel: .binomial)
      let mcRecord  = TheoreticalOptionEODPrice.from(result: mc!,  ..., pricingModel: .monteCarlo)

      Pass optionEODPrice.impliedVolatility to each factory as impliedVolatility input where non-nil.

   f. Upsert each record on (instrument_id, price_date, model)

3. Collect results from all tasks, aggregate counts and failures
4. Return PricingResult
```

**Concurrency notes:**
- Each `withTaskGroup` child task is responsible for one contract (all three models).
- Tasks share a read-only snapshot of the FRED yield curve loaded once before the group starts.
- Each task uses its own `Database` reference to avoid Fluent connection contention.
- The existing pricer internals use `DispatchQueue.concurrentPerform` for Greek bump-and-reprice. This is preserved — no changes needed to pricer code.

**Error handling:**
- Per-contract failures are captured in `failedContracts`. The activity does not throw for individual contract failures.
- If the FRED yield query fails entirely (no rates for today), throw — pricing without a valid rate curve is not meaningful.
- If the activity throws, `RunLogActivity` still records the partial `PricingResult` accumulated before the throw.

---

### 4.5 `RunLogActivity`

**Responsibility:** Write a `job_runs` record summarising the workflow outcome. Always executes regardless of upstream failures.

**Interface:**
```swift
struct RunLogInput: Codable {
    let runDate: Date
    let status: RunStatus
    let portfolioResult: FilteredPositionSet?
    let eodResult: EODPriceResult?
    let optionEODResult: OptionEODResult?
    let pricingResult: PricingResult?
    let errorMessages: [String]
    let startedAt: Date
}

enum RunStatus: String, Codable {
    case success, partial, failed, skipped
}

func runLogActivity(db: Database, input: RunLogInput) async throws
```

**Logic:**
- Derive `status` using the rules in section 3.3.
- Build and upsert a `JobRun` record on `run_date`.
- If a `job_runs` row already exists for `run_date` (e.g. re-run after failure), update it with the latest status and counts.

---

## 5. Data Ingestion Interfaces

### 5.1 Schwab Client Extensions

The existing `SchwabClient` needs two additional methods:

```swift
// Fetch all current brokerage positions
func fetchPortfolioPositions() async throws -> [SchwabPosition]

// Fetch EOD option data for a single contract
func fetchOptionEODPrice(osiSymbol: String) async throws -> SchwabOptionQuote?
```

**`SchwabPosition`:**
```swift
struct SchwabPosition: Codable {
    let ticker: String
    let assetType: SchwabAssetType    // .equity | .option | .other
    let quantity: Double
    let osiSymbol: String?            // populated for options only
    let marketValue: Double?
}

enum SchwabAssetType: String, Codable {
    case equity = "EQUITY"
    case option = "OPTION"
    case other
}
```

**`SchwabOptionQuote`:**
```swift
struct SchwabOptionQuote: Codable {
    let bid: Double?
    let ask: Double?
    let last: Double?
    let volume: Int?
    let openInterest: Int?
    let impliedVolatility: Double?
    let underlyingPrice: Double?
    let delta: Double?
    let gamma: Double?
    let theta: Double?
    let vega: Double?
    let rho: Double?
}
```

**Token refresh:** Before each Schwab API call, check `OAuthToken.isExpired(buffer: 60)`. If expired, call the existing token refresh method and persist the updated `OAuthToken` to `oauth_tokens` before proceeding.

### 5.2 Tiingo Client Interface

The existing `TiingoClient` is assumed to support:

```swift
func fetchEODPrice(ticker: String, date: Date) async throws -> TiingoEODPrice?

struct TiingoEODPrice: Codable {
    let date: Date
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double
    let adjClose: Double?
    let volume: Int?
}
```

If the existing client returns a different shape, add a mapping layer inside `EODPriceActivity` — do not modify the client.

### 5.3 OSI Symbol Parsing

```swift
struct OSIComponents {
    let underlyingTicker: String   // e.g. "AAPL"
    let expirationDate: Date       // e.g. 2026-03-21
    let optionType: OptionType     // .call or .put
    let strikePrice: Double        // e.g. 175.0
}

enum OSIParseError: Error {
    case invalidLength
    case invalidExpiryFormat
    case invalidOptionType
    case invalidStrike
}

func parseOSISymbol(_ osi: String) throws -> OSIComponents
```

**OSI format:** `AAPL  260321C00175000`
- Characters 0–5: underlying ticker, right-padded with spaces (trim whitespace)
- Characters 6–11: expiry `YYMMDD`
- Character 12: option type `C` (call) or `P` (put)
- Characters 13–20: strike × 1000, zero-padded to 8 digits

**Validation:** throw `OSIParseError` if the string is not exactly 21 characters, expiry cannot be parsed as a valid date, option type is not `C` or `P`, or strike string is not numeric.

---

## 6. Database Upsert Patterns

### 6.1 Registering New Option Contracts

Called from `PortfolioActivity` when an option passes the filter but has no `option_contracts` row.

```swift
func registerNewOptionContract(
    osi: OSIComponents,
    osiSymbol: String,
    underlyingInstrument: Instrument,
    db: Database
) async throws -> UUID {

    // Determine type
    let isIndex = underlyingInstrument.instrumentType == .index
    let instrumentType: InstrumentType = isIndex ? .indexOption : .equityOption
    let exerciseStyle: ExerciseStyle   = isIndex ? .european   : .american
    let settlementType                 = isIndex ? "cash"      : "physical"

    // Step 1: create instruments row
    let instrument = Instrument(
        instrumentType: instrumentType,
        ticker: osiSymbol,
        name: "\(osi.underlyingTicker) \(osi.strikePrice) \(osi.optionType) \(osi.expirationDate)",
        currencyCode: "USD",
        isActive: true
    )
    try await instrument.save(on: db)

    // Step 2: create option_contracts row
    let contract = OptionContract(
        instrumentID: instrument.id!,
        underlyingID: underlyingInstrument.id!,
        optionType: osi.optionType,
        exerciseStyle: exerciseStyle,
        strikePrice: osi.strikePrice,
        expirationDate: osi.expirationDate,
        contractMultiplier: 100,
        settlementType: settlementType,
        osiSymbol: osiSymbol
    )
    try await contract.save(on: db)

    return instrument.id!
}
```

**Race condition:** If two workflow executions run simultaneously for the same date (which the workflow ID pattern prevents, but guard against defensively), a duplicate `instruments` insert on `ticker` would violate the unique constraint. Wrap in a `do/catch` for `PostgreSQLError.uniqueViolation` and fall back to fetching the existing row.

### 6.2 EOD Price Upsert

```swift
// Build the model
let eodPrice = EODPrice(
    instrumentID: instrument.id!,
    priceDate: runDate,
    open: tiingoPrice.open,
    high: tiingoPrice.high,
    low: tiingoPrice.low,
    close: tiingoPrice.close,
    adjClose: tiingoPrice.adjClose,
    volume: tiingoPrice.volume,
    source: "tiingo"
)

// Upsert via FluentSQL
try await (db as! SQLDatabase).raw("""
    INSERT INTO eod_prices
        (id, instrument_id, price_date, open, high, low, close, adj_close, volume, source)
    VALUES
        (\(bind: eodPrice.id), \(bind: eodPrice.$instrument.id), \(bind: eodPrice.priceDate),
         \(bind: eodPrice.open), \(bind: eodPrice.high), \(bind: eodPrice.low),
         \(bind: eodPrice.close), \(bind: eodPrice.adjClose), \(bind: eodPrice.volume),
         \(bind: eodPrice.source))
    ON CONFLICT (instrument_id, price_date)
    DO UPDATE SET
        open = EXCLUDED.open, high = EXCLUDED.high, low = EXCLUDED.low,
        close = EXCLUDED.close, adj_close = EXCLUDED.adj_close,
        volume = EXCLUDED.volume, source = EXCLUDED.source
    """).run()
```

### 6.3 Option EOD Price Upsert

Same raw SQL upsert pattern as 6.2, on `(instrument_id, price_date)`.

**Critical:** Never include `mid` in the `INSERT` column list or the `DO UPDATE SET` clause. It is a Postgres generated column (`GENERATED ALWAYS AS ((bid + ask) / 2) STORED`) and will cause a runtime error if written directly.

```swift
// Fields to write:
// bid, ask, last, settlement_price, volume, open_interest,
// implied_volatility, underlying_price, risk_free_rate,
// delta, gamma, theta, vega, rho, dividend_yield, source
// DO NOT include: mid
```

### 6.4 Theoretical Price Upsert

```swift
// Build records using existing factory helpers
let bsRecord  = TheoreticalOptionEODPrice.from(
    result: bsResult, instrumentID: contract.id!, priceDate: runDate,
    riskFreeRate: r, pricingModel: .blackScholes, source: "pipeline"
)
let binRecord = TheoreticalOptionEODPrice.from(
    result: binResult, instrumentID: contract.id!, priceDate: runDate,
    riskFreeRate: r, pricingModel: .binomial, source: "pipeline"
)
let mcRecord  = TheoreticalOptionEODPrice.from(
    result: mcResult, instrumentID: contract.id!, priceDate: runDate,
    riskFreeRate: r, source: "pipeline"   // .monteCarlo inferred by overload
)

// Upsert each on (instrument_id, price_date, model)
for record in [bsRecord, binRecord, mcRecord] {
    try await (db as! SQLDatabase).raw("""
        INSERT INTO theoretical_option_eod_prices
            (id, instrument_id, price_date, price, settlement_price,
             implied_volatility, historical_volatility, risk_free_rate,
             underlying_price, delta, gamma, theta, vega, rho,
             model, model_detail, source)
        VALUES (...)
        ON CONFLICT (instrument_id, price_date, model)
        DO UPDATE SET
            price = EXCLUDED.price,
            settlement_price = EXCLUDED.settlement_price,
            implied_volatility = EXCLUDED.implied_volatility,
            historical_volatility = EXCLUDED.historical_volatility,
            risk_free_rate = EXCLUDED.risk_free_rate,
            underlying_price = EXCLUDED.underlying_price,
            delta = EXCLUDED.delta, gamma = EXCLUDED.gamma,
            theta = EXCLUDED.theta, vega = EXCLUDED.vega, rho = EXCLUDED.rho,
            model_detail = EXCLUDED.model_detail
        """).run()
}
```

---

## 7. Risk-Free Rate Interpolation

### 7.1 Interface

```swift
func interpolateRate(timeToExpiry: Double, db: Database, runDate: Date) async throws -> Double
```

### 7.2 Logic

```
1. Query fred_yields for the most recent observation_date <= runDate:
   SELECT series_id, tenor_years, continuous_rate
   FROM fred_yields
   WHERE observation_date = (
       SELECT MAX(observation_date) FROM fred_yields
       WHERE observation_date <= runDate
   )
   ORDER BY tenor_years ASC

   If no rows returned → throw FREDError.noRatesAvailable

2. Handle edge cases:
   - If timeToExpiry <= shortest tenor_years → return shortest continuous_rate
   - If timeToExpiry >= longest tenor_years  → return longest continuous_rate

3. Find bracketing tenors:
   let lower = last yield where tenor_years <= timeToExpiry
   let upper = first yield where tenor_years > timeToExpiry

4. Linear interpolation:
   let r = lower.continuousRate
           + (upper.continuousRate - lower.continuousRate)
           * (timeToExpiry - lower.tenorYears)
           / (upper.tenorYears - lower.tenorYears)

5. Return r (already continuously compounded — pass directly to pricers)
```

### 7.3 Caching

Load the full yield curve once per `PricingActivity` run (step 1 above) and pass it as a value type to each concurrent pricing task. Do not query `fred_yields` once per contract.

```swift
struct YieldCurve {
    let points: [(tenorYears: Double, continuousRate: Double)]

    func interpolate(timeToExpiry: Double) -> Double { ... }
}
```

---

## 8. Concurrency Model

### 8.1 Between Activities
Sequential within the Temporal workflow. Each activity must complete (or fail) before the next starts.

### 8.2 Within `PricingActivity`

```swift
let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)

let results = try await withThrowingTaskGroup(of: ContractPricingResult.self) { group in
    for contract in eligibleContracts {
        group.addTask {
            try await priceContract(contract, yieldCurve: yieldCurve, db: db, runDate: runDate)
        }
    }
    var collected: [ContractPricingResult] = []
    for try await result in group {
        collected.append(result)
    }
    return collected
}
```

- Each task is responsible for fetching its own EOD history, running all three pricers, and upserting results.
- `YieldCurve` is a value type — safe to share across tasks without synchronisation.
- Each task uses its own `db` reference obtained from the Vapor application's connection pool.

### 8.3 Within Each Pricer

The existing Monte Carlo implementation uses `DispatchQueue.concurrentPerform` for parallel bump-and-reprice in Greek calculation. The Binomial CRR uses serial computation. Neither is modified.

### 8.4 Task Group Sizing

No explicit concurrency limit is set in v1.0. If the number of contracts grows large enough to cause memory pressure, cap the task group with a semaphore or use a chunked approach in v1.1.

---

## 9. `job_runs` Table & Model

### 9.1 Migration

```swift
struct CreateJobRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("job_runs")
            .id()
            .field("run_date",             .date,     .required)
            .field("status",               .string,   .required)   // success|partial|failed|skipped
            .field("equities_fetched",     .int)
            .field("options_fetched",      .int)
            .field("contracts_priced",     .int)
            .field("theoretical_rows",     .int)
            .field("new_contracts",        .int)
            .field("dropped_positions",    .array(of: .string))
            .field("failed_tickers",       .array(of: .string))
            .field("skipped_contracts",    .array(of: .string))
            .field("failed_contracts",     .array(of: .uuid))
            .field("error_messages",       .array(of: .string))
            .field("source_used",          .string)
            .field("started_at",           .datetime, .required)
            .field("completed_at",         .datetime)
            .unique(on: "run_date")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("job_runs").delete()
    }
}
```

### 9.2 Model

```swift
final class JobRun: Model, Content, @unchecked Sendable {
    static let schema = "job_runs"

    @ID var id: UUID?

    @Field(key: "run_date")           var runDate: Date
    @Field(key: "status")             var status: String
    @OptionalField(key: "equities_fetched")    var equitiesFetched: Int?
    @OptionalField(key: "options_fetched")     var optionsFetched: Int?
    @OptionalField(key: "contracts_priced")    var contractsPriced: Int?
    @OptionalField(key: "theoretical_rows")    var theoreticalRows: Int?
    @OptionalField(key: "new_contracts")       var newContracts: Int?
    @OptionalField(key: "dropped_positions")   var droppedPositions: [String]?
    @OptionalField(key: "failed_tickers")      var failedTickers: [String]?
    @OptionalField(key: "skipped_contracts")   var skippedContracts: [String]?
    @OptionalField(key: "failed_contracts")    var failedContracts: [UUID]?
    @OptionalField(key: "error_messages")      var errorMessages: [String]?
    @OptionalField(key: "source_used")         var sourceUsed: String?
    @Field(key: "started_at")         var startedAt: Date
    @OptionalField(key: "completed_at")        var completedAt: Date?

    init() {}
}
```

---

## 10. Logging

Each activity logs the following using Swift structured logging (`Logger`):

| Event | Level | Fields |
|-------|-------|--------|
| Activity start | `.info` | `activity`, `runDate`, `workflowID` |
| Activity complete | `.info` | `activity`, `runDate`, `duration`, key counts |
| Per-item skip/drop | `.warning` | `activity`, `ticker` or `instrumentID`, `reason` |
| Per-item error | `.error` | `activity`, `ticker` or `instrumentID`, `error` |
| Activity failure (will retry) | `.error` | `activity`, `attempt`, `error` |
| Holiday early-exit | `.info` | `runDate`, `"skipping: market holiday"` |
| Token refresh | `.info` | `provider`, `"refreshed"` |

---

## 11. Open Engineering Questions

- Should `EODPriceActivity` and `OptionEODPriceActivity` run concurrently within the workflow in v1.0, or remain sequential for simplicity?
- For `OptionEODPriceActivity`, should contracts with `reason: "no_quote"` be retried within the activity (e.g. with a short delay for illiquid contracts), or accepted as a normal outcome?
- Should the `job_runs` unique constraint be on `run_date` alone (current design), or relaxed to allow multiple records per day to capture both a failed and a subsequent successful run?
- CBOE DataShop integration (DS-03): defer until free tier is confirmed.

---

*— End of Document —*
