# High-Level ERD — Code Review Security & Reliability Hardening

> Generated 2026-03-14 from code review `Projects/002-Code_Review/Code_Review.md`

This ERD captures the full data model as it stands today and annotates the
entities and relationships touched by the 19 code-review findings. It is
intentionally domain-focused — field-level detail lives in the mid/low ERDs.

---

## Entity Relationship Diagram

```mermaid
erDiagram

    %% ─── Reference Data ───────────────────────────────────────────────
    CURRENCY {
        string currency_code PK
        string name
    }

    EXCHANGE {
        uuid   id           PK
        string mic_code
        string name
        string country_code
        string timezone
    }

    MARKET_HOLIDAY {
        uuid   id           PK
        date   holiday_date
        string description
    }

    %% ─── Instrument Registry (table-per-subtype) ────────────────────
    INSTRUMENT {
        uuid   id              PK
        enum   instrument_type "equity | index | equity_option | index_option"
        string ticker
        string name
        uuid   exchange_id     FK
        string currency_code   FK
        bool   is_active
    }

    EQUITY {
        uuid   instrument_id   PK_FK
        string isin
        string cusip
        string figi
        string sector
        string industry
        int    shares_outstanding
    }

    INDEX {
        uuid   instrument_id   PK_FK
        string index_family
        string methodology
        string rebalance_freq
    }

    OPTION_CONTRACT {
        uuid   instrument_id    PK_FK
        uuid   underlying_id    FK
        enum   option_type       "call | put"
        enum   exercise_style    "american | european | bermudan"
        double strike_price
        date   expiration_date
        double contract_multiplier
        string settlement_type
        string osi_symbol
    }

    %% ─── Market Data ────────────────────────────────────────────────
    EOD_PRICE {
        uuid   id            PK
        uuid   instrument_id FK
        date   price_date
        double open
        double high
        double low
        double close
        double adj_close
        int    volume
        double vwap
        string source
    }

    OPTION_EOD_PRICE {
        uuid   id              PK
        uuid   instrument_id   FK
        date   price_date
        double bid
        double ask
        double last
        double settlement_price
        int    volume
        int    open_interest
        double implied_volatility
        double delta
        double gamma
        double theta
        double vega
        double rho
        double underlying_price
        double risk_free_rate
        string source
    }

    THEORETICAL_OPTION_EOD_PRICE {
        uuid   id                   PK
        uuid   instrument_id        FK
        date   price_date
        double price
        double settlement_price
        double implied_volatility
        double historical_volatility
        double risk_free_rate
        double underlying_price
        double delta
        double gamma
        double theta
        double vega
        double rho
        enum   model                 "black_scholes | binomial | monte_carlo"
        string model_detail
        string source
    }

    %% ─── Corporate Events ───────────────────────────────────────────
    CORPORATE_ACTION {
        uuid   id            PK
        uuid   instrument_id FK
        enum   action_type   "split | reverse_split | dividend_cash | dividend_stock | spinoff | merger | delisting"
        date   ex_date
        date   record_date
        date   pay_date
        double ratio
        string notes
    }

    %% ─── Interest Rates (FRED) ──────────────────────────────────────
    FRED_YIELD {
        uuid   id               PK
        enum   series_id         "DGS1MO | DGS3MO | DGS6MO | DGS1 | DGS2 | DGS5"
        date   observation_date
        double yield_percent
        double continuous_rate
        double tenor_years
        string source
    }

    %% ─── Auth / Integration ─────────────────────────────────────────
    OAUTH_TOKEN {
        uuid   id             PK
        string clerk_user_id  "⚠ no unique constraint today"
        string provider       "e.g. schwab"
        string access_token   "encrypted at rest"
        string refresh_token  "encrypted at rest"
        string scope
        date   expires_at
    }

    %% ─── Pipeline Operations ────────────────────────────────────────
    JOB_RUN {
        uuid     id                PK
        date     run_date
        string   status
        int      equities_fetched
        int      options_fetched
        int      contracts_priced
        int      theoretical_rows
        int      new_contracts
        string[] dropped_positions
        string[] failed_tickers
        string[] skipped_contracts
        uuid[]   failed_contracts
        string[] error_messages
        string   source_used
        date     started_at
        date     completed_at
    }

    %% ─── Relationships ───────────────────────────────────────────────
    CURRENCY         ||--o{ INSTRUMENT              : "denominates"
    EXCHANGE         ||--o{ INSTRUMENT              : "lists"
    INSTRUMENT       ||--o| EQUITY                  : "is-a (instrument_type=equity)"
    INSTRUMENT       ||--o| INDEX                   : "is-a (instrument_type=index)"
    INSTRUMENT       ||--o| OPTION_CONTRACT         : "is-a (instrument_type=*_option)"
    INSTRUMENT       ||--o{ EOD_PRICE               : "has daily prices"
    INSTRUMENT       ||--o{ OPTION_EOD_PRICE        : "has option market prices"
    INSTRUMENT       ||--o{ THEORETICAL_OPTION_EOD_PRICE : "has model prices"
    INSTRUMENT       ||--o{ CORPORATE_ACTION        : "has events"
    INSTRUMENT       ||--o{ OPTION_CONTRACT         : "underlies (as underlying_id)"
```

---

## Domain Map

| Domain | Tables | Notes |
|---|---|---|
| Reference Data | `currencies`, `exchanges`, `market_holidays` | Slow-changing lookup data |
| Instrument Registry | `instruments`, `equities`, `indexes`, `option_contracts` | Table-per-subtype; `instrument_id` is shared PK |
| Market Data | `eod_prices`, `option_eod_prices`, `theoretical_option_eod_prices` | Time-series; all FK to `instruments` |
| Corporate Events | `corporate_actions` | FK to `instruments` |
| Interest Rates | `fred_yields` | Independent time-series; no FK |
| Auth / Integration | `oauth_tokens` | Keyed by `(clerk_user_id, provider)` |
| Pipeline Ops | `job_runs` | Standalone audit log; no FK |

---

## Code-Review Findings That Touch This Model

The following issues from the code review have direct data-model implications.
Each is annotated with its severity and the entity/relationship affected.

### Critical

| # | Entity | Finding |
|---|---|---|
| #2 | `OAUTH_TOKEN` | `refreshTokenIfNeeded` in `PortfolioActivity` queries without filtering by `clerk_user_id`, meaning the activity can load and refresh a **different user's** Schwab token. The relationship between the pipeline and `OAUTH_TOKEN` must be scoped by user at every call site. |

### High

| # | Entity | Finding |
|---|---|---|
| #4 | `OAUTH_TOKEN` | No concurrency control on token refresh. Two concurrent requests can both read an expired token, both hit Schwab's refresh endpoint, and both write back — Schwab refresh tokens are single-use, so the second write corrupts the session. A DB-level `SELECT FOR UPDATE` or actor serialization is needed. |
| #7 | _(no table)_ | Three divergent in-memory `SchwabTokenResponse` structs decode Schwab's token response. Consolidating them ensures consistent deserialization before values reach `OAUTH_TOKEN`. |

### Medium

| # | Entity | Finding |
|---|---|---|
| #14 | _(sessions, not Postgres)_ | Flash messages rely on server-side sessions. `app.sessions.use(.memory)` means session state is lost on restart or across Render instances. Migrate to Redis or DB-backed sessions. |

### Design / Infrastructure

| # | Entity | Finding |
|---|---|---|
| #8 | _(all tables)_ | `autoMigrate()` runs on every server startup. Any destructive migration executes across all Render instances simultaneously, with no rollback window. Migrations should be a discrete pre-deploy step. |
| #19 | _(all tables)_ | `maxConnectionsPerEventLoop: 2` caps the Postgres connection pool at ≤8 connections on a 4-core host. The daily pipeline issues concurrent queries across `EOD_PRICE`, `OPTION_EOD_PRICE`, `THEORETICAL_OPTION_EOD_PRICE`, and `JOB_RUN` and will hit the 30-second pool timeout under realistic load. |

---

## Open Design Gap: `OAUTH_TOKEN` Ownership

`OAUTH_TOKEN` currently has no database-level uniqueness constraint on
`(clerk_user_id, provider)`. A user who re-authorizes Schwab will accumulate
multiple token rows; `refreshTokenIfNeeded` picks whichever `.first()` Fluent
returns. The mid-ERD should specify a unique index on `(clerk_user_id, provider)`
and a replace-or-update upsert strategy on token write.
