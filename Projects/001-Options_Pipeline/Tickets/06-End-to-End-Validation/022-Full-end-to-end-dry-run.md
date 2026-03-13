# TICKET-022 · Full end-to-end dry run on a live trading day

**Task:** Trigger the full `DailyPipelineWorkflow` manually (or wait for the 4:00 PM ET schedule) on a live trading day and validate all outputs.

**Validation checklist:**
- `job_runs` has exactly one row for today with `status = "success"` (or `"partial"` with logged reasons).
- `eod_prices` has rows for all active instruments in `equities` and `indexes` with `price_date = today`.
- `option_eod_prices` has rows for all non-expired contracts with `price_date = today`. No row has a non-null `mid` that was written by the pipeline (it is generated).
- `theoretical_option_eod_prices` has exactly 3 rows per non-expired contract (`black_scholes`, `binomial`, `monte_carlo`) with `price_date = today`.
- Re-triggering the workflow for the same date (same workflow ID) is rejected by Temporal as a duplicate.
- Temporal UI shows all five activities as `Completed`.
