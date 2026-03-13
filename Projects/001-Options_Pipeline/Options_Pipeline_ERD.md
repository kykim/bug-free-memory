# Engineering Requirements Document
## Equity Index Options Data Pipeline & Pricer
**Version 1.0 | March 2026 | Confidential**

---

## 1. Overview

This document describes the engineering design for the automated daily options data pipeline defined in the PRD. It covers system architecture, Temporal workflow and activity design, data ingestion interfaces, pricing pipeline wiring, and database upsert patterns.

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
│  │    └── PricingActivity                       │        │
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

### 2.3 File Structure

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

### 2.2 Key Design Principles Scheduling, retries, and failure isolation are delegated entirely to Temporal. No Vapor scheduled jobs.
- **Database is the source of truth for scope.** Which instruments, options, and contracts are processed is determined entirely by querying existing tables — not by hardcoded symbols or runtime config.
- **All writes are upserts.** Every database write uses `ON CONFLICT DO UPDATE` to guarantee idempotency. Re-running the workflow for the same date produces no duplicates.
- **Existing code is wired, not rewritten.** The Schwab client, Tiingo client, FRED interpolation, and all three pricers already exist. This pipeline wires them together in a defined execution order.

---

## 3. Temporal Workflow Design

### 3.1 Workflow: `DailyPipelineWorkflow`

**Workflow ID pattern:** `daily-pipeline-YYYYMMDD` (scoped to run date to prevent duplicate executions)

**Schedule:** Temporal cron schedule triggering at `16:00 ET` on weekdays.

**Early-exit condition:** At workflow start, check whether the run date is a US market holiday (using the configured holiday list). If so, log and return without executing any activities.

**Activity execution order:**

```
DailyPipelineWorkflow
  │
  ├─ 1. PortfolioActivity
  │       └─ outputs: FilteredPositionSet (equity instrument_ids + option instrument_ids)
  │
  ├─ 2. EODPriceActivity          (depends on FilteredPositionSet)
  │       └─ outputs: EODPriceResult (rows upserted)
  │
  ├─ 3. OptionEODPriceActivity    (depends on FilteredPositionSet)
  │       └─ outputs: OptionEODResult (rows upserted)
  │
  ├─ 4. PricingActivity           (depends on OptionEODResult)
  │       └─ outputs: PricingResult (rows upserted per model)
  │
  └─ 5. RunLogActivity            (always runs, even if upstream activities fail)
          └─ writes job_runs record with final status + counts
```

**Failure behaviour:** If an activity fails after exhausting retries, subsequent dependent activities are skipped. `RunLogActivity` always executes to record the run outcome.

### 3.2 Activity Retry Policies

| Activity | Max Attempts | Initial Interval | Backoff Coefficient |
|----------|-------------|-----------------|---------------------|
| PortfolioActivity | 3 | 30s | 2.0 |
| EODPriceActivity | 3 | 30s | 2.0 |
| OptionEODPriceActivity | 3 | 30s | 2.0 |
| PricingActivity | 2 | 10s | 1.5 |
| RunLogActivity | 5 | 5s | 1.5 |

---

## 4. Activity Design

### 4.1 `PortfolioActivity`

**Responsibility:** Download Schwab portfolio positions, apply two-pass filter, register any new option contracts.

**Interface:**
```swift
struct FilteredPositionSet: Codable {
    let equityInstrumentIDs: [UUID]
    let optionInstrumentIDs: [UUID]
    let droppedPositions: [String]   // tickers dropped, for logging
    let runDate: Date
}

func portfolioActivity(db: Database, schwabClient: SchwabClient) async throws -> FilteredPositionSet
```

**Logic:**
1. Fetch all positions from Schwab via existing OAuth client.
2. **Equity filter:** for each equity position, query `instruments JOIN equities WHERE ticker = position.ticker AND instrument_type = 'equity'`. Keep if found; drop and log if not.
3. **Option filter:** parse OSI symbol to extract underlying ticker. Query `instruments JOIN equities WHERE ticker = underlyingTicker`. Keep if found; drop and log if not.
4. **Drop everything else** (funds, cash, fixed income). Log dropped types.
5. **Register new option contracts:** for each option that passed the filter, check `option_contracts WHERE osi_symbol = ?`. If missing, create `instruments` row then `option_contracts` row (see section 6.1).
6. Return `FilteredPositionSet` containing surviving `instrument_id` arrays.

---

### 4.2 `EODPriceActivity`

**Responsibility:** Fetch and persist EOD closing prices for all active instruments in `equities` and `indexes` tables.

**Interface:**
```swift
struct EODPriceResult: Codable {
    let rowsUpserted: Int
    let instrumentsFetched: Int
    let source: String
}

func eodPriceActivity(db: Database, tiingoClient: TiingoClient) async throws -> EODPriceResult
```

**Logic:**
1. Build eligible instrument list: query `instruments LEFT JOIN equities` UNION `instruments LEFT JOIN indexes` where matching row exists and `is_active = true`.
2. For each eligible instrument, fetch EOD price from Tiingo using `ticker`.
3. Upsert into `eod_prices` on `(instrument_id, price_date)`.
4. Return counts.

> **Note:** This activity is independent of `FilteredPositionSet` — it runs against all active instruments in the DB, not just those in today's portfolio. The portfolio filter only gates option pricing, not EOD price collection.

---

### 4.3 `OptionEODPriceActivity`

**Responsibility:** Fetch and persist EOD prices for all non-expired option contracts.

**Interface:**
```swift
struct OptionEODResult: Codable {
    let contractsProcessed: Int
    let rowsUpserted: Int
    let contractsSkipped: Int   // expired
}

func optionEODPriceActivity(db: Database, schwabClient: SchwabClient) async throws -> OptionEODResult
```

**Logic:**
1. Query `option_contracts WHERE expiration_date >= today`. These are the only eligible contracts.
2. For each contract, fetch EOD data from Schwab using `osi_symbol` (preferred) or `(underlying ticker, strike, expiration, option_type)` as fallback.
3. Upsert into `option_eod_prices` on `(instrument_id, price_date)`. Do not write `mid` — it is a generated column.
4. Return counts.

---

### 4.4 `PricingActivity`

**Responsibility:** Run all three pricing models over each non-expired option contract and persist results.

**Interface:**
```swift
struct PricingResult: Codable {
    let contractsPriced: Int
    let rowsUpserted: Int        // contractsPriced × 3 models
    let failedContracts: [UUID]  // instrument_ids where pricing returned nil
}

func pricingActivity(db: Database, fredClient: FREDClient) async throws -> PricingResult
```

**Logic:**
1. Query `option_contracts WHERE expiration_date >= today`, eager-load `underlying` instrument.
2. For each contract:
   a. Fetch `EODPrice` history for the underlying from `eod_prices` (last 31 days, sorted ascending).
   b. Interpolate risk-free rate `r` from `fred_yields` using the contract's `timeToExpiry()` and `continuous_rate`.
   c. Run `blackScholesPrice(currentPrice:priceHistory:riskFreeRate:)`.
   d. Run `binomialPrice(currentPrice:priceHistory:riskFreeRate:)`.
   e. Run `monteCarloPrice(currentPrice:priceHistory:riskFreeRate:)`.
   f. Build `TheoreticalOptionEODPrice` records using existing `.from(result:...)` factory helpers.
   g. Upsert into `theoretical_option_eod_prices` on `(instrument_id, price_date, model)`.
3. Run contract pricing concurrently using Swift structured concurrency (`withTaskGroup`).
4. Return counts and any failed contract IDs.

---

### 4.5 `RunLogActivity`

**Responsibility:** Write a `job_runs` record summarising the workflow outcome. Always executes.

**Interface:**
```swift
struct RunLogInput: Codable {
    let runDate: Date
    let status: String                  // "success" | "partial" | "failed"
    let portfolioResult: FilteredPositionSet?
    let eodResult: EODPriceResult?
    let optionEODResult: OptionEODResult?
    let pricingResult: PricingResult?
    let errorMessages: [String]
}

func runLogActivity(db: Database, input: RunLogInput) async throws
```

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

**`SchwabPosition`** should expose: `ticker`, `assetType` (equity/option), `quantity`, `osiSymbol?`

**`SchwabOptionQuote`** should expose: `bid`, `ask`, `last`, `volume`, `openInterest`, `impliedVolatility`, `underlyingPrice`, `delta`, `gamma`, `theta`, `vega`, `rho`

### 5.2 OSI Symbol Parsing

The pipeline needs a utility to parse OSI symbols into their components for option contract registration and underlying lookup:

```swift
struct OSIComponents {
    let underlyingTicker: String   // e.g. "AAPL"
    let expirationDate: Date       // e.g. 2026-03-21
    let optionType: OptionType     // .call or .put
    let strikePrice: Double        // e.g. 175.0
}

func parseOSISymbol(_ osi: String) throws -> OSIComponents
```

OSI format: `AAPL  260321C00175000` → underlying (6), expiry YYMMDD (6), type (1), strike × 1000 (8)

---

## 6. Database Upsert Patterns

### 6.1 Registering New Option Contracts

When a new option is encountered in the portfolio that has no matching `option_contracts` row:

```swift
// Step 1: create instruments row
let instrument = Instrument(
    instrumentType: isIndex ? .indexOption : .equityOption,
    ticker: osiComponents.osiSymbol,
    name: "\(underlyingTicker) \(strike) \(optionType) \(expiry)",
    currencyCode: "USD",
    isActive: true
)
try await instrument.save(on: db)

// Step 2: create option_contracts row
let contract = OptionContract(
    instrumentID: instrument.id!,
    underlyingID: underlyingInstrument.id!,
    optionType: osiComponents.optionType,
    exerciseStyle: isIndex ? .european : .american,
    strikePrice: osiComponents.strikePrice,
    expirationDate: osiComponents.expirationDate,
    contractMultiplier: 100,
    settlementType: isIndex ? "cash" : "physical",
    osiSymbol: osiSymbol
)
try await contract.save(on: db)
```

### 6.2 EOD Price Upsert

```swift
// Uses FluentSQL raw upsert for ON CONFLICT DO UPDATE
try await db.query(EODPrice.self)
    .upsert(
        conflictingWith: [\.$instrument, \.$priceDate],
        updating: [\.$open, \.$high, \.$low, \.$close, \.$adjClose, \.$volume, \.$source]
    )
```

### 6.3 Option EOD Price Upsert

Same pattern as 6.2, on `(instrument_id, price_date)`. **Never include `mid`** in the field list — it is a Postgres generated column.

### 6.4 Theoretical Price Upsert

```swift
// Three upserts per contract, one per model
for result in [bsRecord, binomialRecord, mcRecord] {
    try await db.query(TheoreticalOptionEODPrice.self)
        .upsert(
            conflictingWith: [\.$instrument, \.$priceDate, \.$model],
            updating: [\.$price, \.$settlementPrice, \.$impliedVolatility,
                       \.$historicalVolatility, \.$riskFreeRate, \.$underlyingPrice,
                       \.$delta, \.$gamma, \.$theta, \.$vega, \.$rho, \.$modelDetail]
        )
}
```

---

## 7. Risk-Free Rate Interpolation

The existing FRED infrastructure provides `fred_yields` rows with `tenorYears` and `continuousRate`. For each option contract, derive `r` as follows:

1. Query `fred_yields WHERE observation_date = runDate` ordered by `tenor_years ASC`.
2. Find the two tenor brackets surrounding the contract's `timeToExpiry()`.
3. Linear interpolation: `r = r1 + (r2 - r1) * (T - t1) / (t2 - t1)`
4. If `T` is below the shortest tenor, use the shortest rate. If above the longest, use the longest.
5. Pass the interpolated `continuousRate` directly as `riskFreeRate` to all three pricers.

---

## 8. Concurrency Model

- **Between activities:** Sequential within the Temporal workflow. Each activity completes before the next starts.
- **Within `PricingActivity`:** Contracts are priced concurrently using `withTaskGroup`. Each task prices one contract across all three models.
- **Within each pricer:** The existing Monte Carlo and Binomial implementations use `DispatchQueue.concurrentPerform` internally for Greek bumps. This is preserved as-is.
- **Database access:** Each concurrent pricing task gets its own Fluent `Database` reference. No shared mutable state across tasks.

---

## 9. `job_runs` Table

This table does not yet exist and needs a migration:

```swift
struct CreateJobRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("job_runs")
            .id()
            .field("run_date",            .date,     .required)
            .field("status",              .string,   .required)  // success | partial | failed
            .field("equities_fetched",    .int)
            .field("options_fetched",     .int)
            .field("contracts_priced",    .int)
            .field("theoretical_rows",    .int)
            .field("dropped_positions",   .array(of: .string))
            .field("failed_contracts",    .array(of: .uuid))
            .field("error_messages",      .array(of: .string))
            .field("source_used",         .string)
            .field("started_at",          .datetime, .required)
            .field("completed_at",        .datetime)
            .unique(on: "run_date")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("job_runs").delete()
    }
}
```

---

## 10. Open Engineering Questions

- Should `EODPriceActivity` also accept `FilteredPositionSet` to optionally restrict fetching to portfolio holdings only, or should it always fetch all active instruments?
- For `OptionEODPriceActivity`, what is the fallback behaviour if Schwab returns no quote for a given `osi_symbol` (e.g. illiquid contract)? Skip silently, log warning, or mark as stale?
- Should the `job_runs` unique constraint be on `run_date` alone, or on `(run_date, status)` to allow recording both a failed and a successful run on the same date?
- CBOE DataShop integration (DS-03): defer until free tier is confirmed. No engineering work required until then.

---

*— End of Document —*
