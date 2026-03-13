# TICKET-022: Full End-to-End Dry Run Checklist

Run on a live trading day after the 4:00 PM ET schedule fires (or trigger manually).

## Pre-flight

- [ ] Temporal server running and accessible at `localhost:7233`
- [ ] Worker started: `vapor run worker --env production`
- [ ] Schedule registered: `vapor run register-schedule --env production`
- [ ] `SCHWAB_ACCOUNT_NUMBER`, `SCHWAB_CLIENT_ID`, `SCHWAB_CLIENT_SECRET` set
- [ ] `TIINGO_API_KEY` set
- [ ] `TOKEN_ENCRYPTION_KEY` set (32-byte base64)
- [ ] Schwab OAuth token present in `oauth_tokens` table (provider = "schwab")

## Trigger

Either wait for the 4:00 PM ET schedule, or trigger manually via Temporal UI:
1. Open Temporal UI → Schedules → `daily-pipeline-schedule`
2. Click "Trigger now"

## Validation Queries

### 1. job_runs — exactly one row for today, status = "success" or "partial"
```sql
SELECT run_date, status, equities_fetched, options_fetched,
       contracts_priced, theoretical_rows, new_contracts,
       array_length(error_messages, 1) AS error_count,
       started_at, completed_at
FROM job_runs
WHERE run_date = CURRENT_DATE;
```
Expected: 1 row, `status` in ('success', 'partial')

### 2. eod_prices — rows for all active equity/index instruments
```sql
SELECT COUNT(*) AS eod_rows
FROM eod_prices
WHERE price_date = CURRENT_DATE;
```
Expected: matches count of active instruments in equities + indexes

### 3. option_eod_prices — no NULL mid written by pipeline (it is generated)
```sql
SELECT instrument_id, price_date, bid, ask, mid
FROM option_eod_prices
WHERE price_date = CURRENT_DATE
LIMIT 10;
```
Expected: `mid` is auto-computed from `(bid + ask) / 2` by Postgres

### 4. theoretical_option_eod_prices — exactly 3 rows per contract
```sql
SELECT instrument_id, COUNT(*) AS model_count
FROM theoretical_option_eod_prices
WHERE price_date = CURRENT_DATE
GROUP BY instrument_id
HAVING COUNT(*) != 3;
```
Expected: 0 rows

### 5. Temporal duplicate rejection — re-triggering same workflow ID is rejected
Trigger `daily-pipeline-<TODAY>` a second time from the Temporal UI.
Expected: Temporal rejects with "workflow already exists" for same ID.

### 6. Temporal UI
- [ ] All five activities show as `Completed`
- [ ] No activities in `Failed` or `TimedOut` state
- [ ] Workflow status = `Completed`
