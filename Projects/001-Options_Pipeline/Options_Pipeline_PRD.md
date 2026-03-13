# Product Requirements Document
## Equity Index Options Data Pipeline & Pricer
**Version 1.0 | March 2026 | Confidential**

---

## 1. Overview

This document defines the product requirements for an automated daily data pipeline and option pricing engine integrated into the existing Swift/Vapor application running locally with a PostgreSQL backend. The system will download equity index and option closing prices from multiple data sources at end of trading day, compute theoretical option prices and Greeks using three pricing models, and persist all data to the database — all without manual intervention.

---

## 2. Goals & Non-Goals

### 2.1 Goals
- Automate daily ingestion of SPX/SPY closing prices and options chain data.
- Compute Black-Scholes, Binomial CRR, and Monte Carlo (LSM) option prices.
- Compute full Greeks: delta, gamma, vega, theta (and optionally rho).
- Store all raw market data and computed results in PostgreSQL via Fluent ORM.
- Run end-to-end without any manual prompting, triggered at 4:00 PM ET on each trading day.

### 2.2 Non-Goals (v1.0)
- Real-time or intraday data ingestion.
- UI for browsing or visualizing pricing results (can be added in v1.1).
- Support for equity indices beyond SPX/SPY.
- Trade execution or order management.

---

## 3. Users & Stakeholders

Primary user: Developer/quant (Kevin) — sole operator of the local Vapor app. The system is fully automated; no end-user interaction is required for daily operation. Results in PostgreSQL may be consumed by downstream Leaf-templated dashboards or API endpoints in future iterations.

---

## 4. Data Sources

### 4.1 Primary Sources

| ID | Source | Details / Constraints |
|----|--------|-----------------------|
| DS-01 | Schwab Developer API | OAuth 2.0 integration already built. Extend to pull SPX/SPY closing price and full options chain. |
| DS-02 | Tiingo | REST API integration already built. Pull SPX/SPY end-of-day closing price. Used as fallback or cross-validation source. |
| DS-03 | CBOE DataShop | Use only if a free tier is available. Pull SPX settlement and options data. Optional — skip if not free. |

### 4.2 Source Priority & Fallback
- Attempt Schwab API first for options chain data (most complete).
- Fall back to Tiingo for index closing price if Schwab is unavailable.
- CBOE DataShop is supplementary; integrate only if free tier confirmed.
- Log source used for each daily run to the database for auditability.

---

## 5. Scheduling & Automation

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| SCH-01 | Trigger daily job at 4:00 PM ET on trading days | Implemented as a Temporal workflow schedule (cron-style). Skip weekends and US market holidays. |
| SCH-02 | Market holiday detection | Maintain a configurable list of US market holidays. Workflow starts but exits early on non-trading days. |
| SCH-03 | Retry on failure | Activity-level retries configured in Temporal (default: 3 attempts, exponential backoff). |
| SCH-04 | Run log | Write a record of each run (timestamp, status, source used, rows ingested) to a `job_runs` table in Postgres on workflow completion. |

---

## 6. Data Ingestion Requirements

### 6.1 Portfolio Download & Filtering

The pipeline downloads all current brokerage positions from Schwab and applies a two-pass filter to determine which positions are in scope for EOD price ingestion and option pricing. Positions that do not pass the filter are dropped and logged.

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| ING-01 | Download portfolio positions from Schwab | Use existing Schwab OAuth client to fetch all current brokerage positions as the first step of the 4:00 PM ET daily job. No persistence of raw positions is required. |
| ING-02 | Filter: equity positions | For each equity position in the portfolio, look up the ticker in `instruments JOIN equities` (WHERE `instrument_type = 'equity'`). Keep the position if a matching row exists. Drop and log if not found. |
| ING-03 | Filter: option positions | For each option position in the portfolio, extract the underlying ticker (e.g. via OSI symbol parsing). Look up that underlying ticker in `instruments JOIN equities`. Keep the option position if the underlying exists in equities. Drop and log if not found. |
| ING-04 | Drop all other position types | Any position that is neither an equity nor an option (e.g. mutual funds, fixed income, cash) is dropped and logged. Not in scope for v1.0. |
| ING-05 | Register new option contracts | For each option position that passes the filter in ING-03, check whether a matching row exists in `option_contracts` by `osi_symbol`. If not found: (1) create a new `instruments` row with `instrument_type = equity_option` or `index_option`, `is_active = true`; (2) create a new `option_contracts` row linked to that instrument and to the underlying's `instrument_id`. Fields populated from OSI symbol: `option_type`, `strike_price`, `expiration_date`. `exercise_style` defaults to `american` for equity options, `european` for index options. |
| ING-06 | Filtered position set drives downstream steps | The set of equity and option `instrument_id`s that passed the filter in ING-02/ING-03 is used as the input to all subsequent ingestion (sections 6.2–6.4) and pricing (section 7) steps. |

### 6.2 EOD Closing Prices

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| ING-07 | Build eligible instrument list | Query `instruments LEFT JOIN equities` and `instruments LEFT JOIN indexes`. Collect all `instrument_id`s where a matching row exists in either table and `is_active = true`. This list gates which closing prices are fetched. |
| ING-08 | Fetch closing prices for eligible instruments only | For each `instrument_id` in the eligible list, fetch the EOD closing price via Tiingo (equities) or the appropriate source (indexes). Skip any instrument not in the eligible list — do not fetch and do not log as an error. |
| ING-09 | Upsert into `eod_prices` | Write fields: `instrument_id`, `price_date`, `open`, `high`, `low`, `close`, `adj_close`, `volume`, `source`. Use `ON CONFLICT (instrument_id, price_date) DO UPDATE` to remain idempotent. |

### 6.3 Option EOD Prices

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| ING-10 | Build eligible option contract list | Query `option_contracts WHERE expiration_date >= today`. These are the only contracts for which EOD prices are fetched. Expired contracts are skipped entirely. |
| ING-11 | Fetch EOD price per eligible contract | For each non-expired `option_contract`, fetch the closing `bid`, `ask`, `last`, `volume`, `open_interest`, and `implied_volatility` from Schwab using the contract's `osi_symbol` or `(underlying, strike, expiration, option_type)` as the lookup key. |
| ING-12 | Upsert into `option_eod_prices` | Upsert on `(instrument_id, price_date)`. Fields: `bid`, `ask`, `last`, `settlement_price`, `volume`, `open_interest`, `implied_volatility`, `underlying_price`, `risk_free_rate`, `source`. Do not write `mid` — it is a Postgres generated column computed as `(bid + ask) / 2`. |

---

## 7. Option Pricing Requirements

### 7.1 Pricing Models

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| PRC-01 | Black-Scholes | Analytical closed-form for European options. Inputs: S, K, T, r, sigma. Output: theoretical price. |
| PRC-02 | Binomial CRR | Cox-Ross-Rubinstein binomial tree. Configurable number of steps (default: 100). Supports American-style early exercise. |
| PRC-03 | Monte Carlo (LSM) | Longstaff-Schwartz least-squares Monte Carlo. Configurable number of paths (default: 10,000) and time steps. Supports American-style. |

### 7.2 Greeks

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| GRK-01 | Delta | First derivative of price w.r.t. underlying. Compute for all three models where applicable. |
| GRK-02 | Gamma | Second derivative of price w.r.t. underlying. |
| GRK-03 | Vega | Sensitivity to implied volatility (1% bump). |
| GRK-04 | Theta | Daily time decay. |
| GRK-05 | Implied Volatility source | Use market IV from fetched options chain as sigma input. Fall back to computed IV from last price if unavailable. |

### 7.3 Storage of Computed Results

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| PRC-06 | Upsert into `theoretical_option_eod_prices` | Write one row per contract per model. Unique constraint on `(instrument_id, price_date, model)` handles re-runs. Model enum values: `black_scholes`, `binomial`, `monte_carlo`. |
| PRC-07 | Use `TheoreticalOptionEODPrice` factory helpers | Use existing `TheoreticalOptionEODPrice.from(result:...)` factory methods to build records from `OptionPriceResult` (BS/CRR) and `MonteCarloResult` (LSM). |
| PRC-08 | Populate `model_detail` | Persist the human-readable model label from the pricer (e.g. "Binomial CRR (American, 200 steps)") into the `model_detail` field. |

### 7.4 Risk-Free Rate

Use the existing FRED Treasury yield interpolation infrastructure already in the project. Query `fred_yields` for the `observation_date` matching the run date, then interpolate using `tenor_years` and `continuous_rate` to derive `r` for each contract's time-to-expiry.

---

## 8. Data Storage

### 8.1 Existing Schema

All tables and migrations already exist. The pipeline writes to the following tables:

| Table | Description | Key Fields |
|-------|-------------|------------|
| `instruments` | Core instrument registry | `id` (UUID), `instrument_type` (equity \| index \| equity_option \| index_option), `ticker`, `name`, `exchange_id` (FK), `currency_code` (FK), `is_active`. Unique on `(ticker, exchange_id)`. |
| `equities` | Equity-specific metadata | `instrument_id` (PK/FK), `isin`, `cusip`, `figi`, `sector`, `industry`, `shares_outstanding`. Used as the symbol filter source for the pipeline. |
| `indexes` | Index-specific metadata | `instrument_id` (PK/FK), `index_family`, `methodology`, `rebalance_freq`. |
| `eod_prices` | Equity/index EOD prices | `id`, `instrument_id` (FK), `price_date`, `open`, `high`, `low`, `close` (required), `adj_close`, `volume`, `vwap`, `source`, `created_at`. Unique on `(instrument_id, price_date)`. Indexed on `(instrument_id, price_date DESC)`. |
| `option_contracts` | Option contract definitions | `instrument_id` (PK/FK), `underlying_id` (FK → instruments), `option_type` (call\|put), `exercise_style` (american\|european\|bermudan), `strike_price`, `expiration_date`, `contract_multiplier` (default 100), `settlement_type`, `osi_symbol`. Indexed on `(underlying_id, expiration_date, strike_price)`. |
| `option_eod_prices` | Raw market option EOD prices | `id`, `instrument_id` (FK), `price_date`, `bid`, `ask`, `mid` (generated), `last`, `settlement_price`, `volume`, `open_interest`, `implied_volatility`, `delta`, `gamma`, `theta`, `vega`, `rho`, `underlying_price`, `risk_free_rate`, `dividend_yield`, `source`. Unique on `(instrument_id, price_date)`. |
| `theoretical_option_eod_prices` | Model-computed option prices | `id`, `instrument_id` (FK), `price_date`, `price`, `settlement_price`, `implied_volatility`, `historical_volatility`, `risk_free_rate`, `underlying_price`, `delta`, `gamma`, `theta`, `vega`, `rho`, `model` (black_scholes\|binomial\|monte_carlo), `model_detail`, `source`. Unique on `(instrument_id, price_date, model)`. |
| `fred_yields` | FRED Treasury yield curve data | `id`, `series_id` (DGS1MO\|DGS3MO\|DGS6MO\|DGS1\|DGS2\|DGS5), `observation_date`, `yield_percent`, `continuous_rate`, `tenor_years`, `source`. Unique on `(series_id, observation_date)`. |
| `oauth_tokens` | Schwab OAuth tokens | `id`, `clerk_user_id`, `provider` (e.g. schwab), `access_token`, `refresh_token`, `scope`, `expires_at`. Unique on `(clerk_user_id, provider)`. Used by pipeline to authenticate with Schwab API. |

### 8.2 Pipeline Write Targets

- **Portfolio ingest:** read-only query against `instruments` + `equities` tables to build the filtered symbol list. No writes to these tables from the pipeline.
- **Index EOD prices:** upsert into `eod_prices (instrument_id, price_date)`.
- **Option EOD prices:** upsert into `option_eod_prices (instrument_id, price_date)` per contract fetched from Schwab.
- **Option contracts:** upsert into `option_contracts (osi_symbol)` when new contracts are encountered that don't yet exist.
- **Theoretical prices:** upsert into `theoretical_option_eod_prices (instrument_id, price_date, model)` — three rows per contract (one per pricing model).
- All uniqueness constraints are enforced at the DB level — the pipeline must use `ON CONFLICT DO UPDATE` (upsert) semantics to remain idempotent.

---

## 9. Configuration

All configurable parameters should be externalized via environment variables or a local config file (e.g. `config/options.json`), not hardcoded.

| ID | Parameter | Details / Constraints |
|----|----------|-----------------------|
| CFG-01 | Data source priority | Ordered list: `[schwab, tiingo, cboe]`. Fallback order for EOD price fetching. |
| CFG-02 | Market holiday list | Array of ISO dates to skip. Updated annually. |
| CFG-03 | Job run time | Default: `16:00 ET`. Configurable for testing. |

---

## 10. Non-Functional Requirements

| ID | Requirement | Details / Constraints |
|----|-------------|-----------------------|
| NFR-01 | Workflow orchestration — Temporal | The daily pipeline is implemented as a Temporal workflow using the Apple Swift Temporal SDK. Each logical stage (portfolio download, EOD price fetch, option EOD fetch, pricing) is a separate Temporal activity. The Temporal worker runs locally alongside the Vapor app. |
| NFR-02 | Scheduling | The Temporal workflow is triggered daily at 4:00 PM ET via a Temporal schedule (cron-style). Market holiday detection is handled within the workflow — the workflow starts but exits early on non-trading days. Replaces any Vapor-native scheduled job. |
| NFR-03 | Retry logic | Activity-level retries are configured in Temporal (default: 3 attempts, exponential backoff). Failures in one activity do not abort the workflow — downstream activities that depend on the failed stage are skipped; independent stages continue. Retry policy is configurable per activity. |
| NFR-04 | Observability | Temporal UI provides workflow execution history, activity status, and failure traces. Additionally, log each activity start/complete with duration and row counts using Swift structured logging. Run outcome (status, counts, errors) is recorded in the `job_runs` table on workflow completion. |
| NFR-05 | Concurrency | Pricing computations run concurrently per contract using Swift async/await and actor isolation within the pricing activity. Temporal activities themselves run sequentially in the defined workflow order. |
| NFR-06 | Idempotency | Re-running the workflow for the same date upserts, not duplicates, all records. Temporal workflow IDs should be scoped to the run date (e.g. `daily-pipeline-20260313`) to prevent duplicate workflow executions for the same day. |
| NFR-07 | Local-only | No cloud deployment required for v1.0. Temporal server, worker, and Vapor app all run locally on the developer's machine. |

---

## 11. Open Questions

- Is CBOE DataShop free tier available and sufficient for SPX options? If not, deprioritize DS-03.
- Should computed prices be compared/validated against market last price, and discrepancies flagged?
- Should a simple Leaf dashboard be scoped into v1.1 for browsing daily results?
- Are American-style SPX options in scope, or European only? (SPX is European; SPY is American — CRR/LSM are needed for SPY puts.)


---

## 12. Suggested Build Milestones

| Milestone | Description | Notes |
|-----------|-------------|-------|
| M1 | Ingest — portfolio positions | Wire existing Schwab client to pull personal brokerage positions. Cross-reference symbols against `instruments`/`equities` tables to produce filtered symbol list. [Schwab OAuth: DONE] |
| M2 | Ingest — index prices | Wire existing Tiingo client to pull closing prices for all instruments in `equities` and `indexes` tables and persist to `eod_prices`. [Tiingo client: DONE] |
| M3 | Ingest — option EOD prices | Wire existing Schwab client to fetch EOD prices for all non-expired contracts in `option_contracts`. Register any new contracts encountered. [Schwab OAuth: DONE] |
| M4 | Pricing pipeline | Wire existing pricers (Black-Scholes, CRR, LSM) and Greeks over each ingested contract. Use existing FRED rate interpolation for r. Persist to `theoretical_option_eod_prices`. [Pricers + schema: DONE] |
| M5 | Temporal workflow & scheduling | Implement Temporal workflow with one activity per pipeline stage (portfolio, EOD prices, option EOD prices, pricing). Configure Temporal schedule for 4:00 PM ET trigger. Add market holiday early-exit logic, per-activity retry policies, and run logging to `job_runs` on completion. Uses Apple Swift Temporal SDK. |
| M6 | End-to-end test | Run full pipeline on a live trading day. Validate all ingested and computed records in Postgres. Confirm no duplicate records on re-run (idempotency). |

---

*— End of Document —*
