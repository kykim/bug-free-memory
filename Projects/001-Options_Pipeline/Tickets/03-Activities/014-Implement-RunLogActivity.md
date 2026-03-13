# TICKET-014 · Implement `RunLogActivity`

**File:** `Sources/bug-free-memory/Activities/RunLogActivity.swift`

**Task:** Implement the Temporal activity that writes the `job_runs` record. Always executes, even if upstream activities failed.

**Depends on:** TICKET-001, TICKET-002, TICKET-003.

**Logic:**
1. Build a `JobRun` model from `RunLogInput` fields.
2. Derive array fields: `droppedPositions` as `"\(ticker): \(reason)"` strings. `skippedContracts` as `osiSymbol ?? "\(instrumentID)"` strings. `failedContracts` as `[UUID]`.
3. Upsert into `job_runs` on `(run_date)` via raw SQL `ON CONFLICT (run_date) DO UPDATE SET ...` — all fields except `id` and `started_at` should be updated on conflict.
4. Log `.info` on complete with `runDate`, `status`, `duration`.

**Retry policy:** 5 attempts, 5s initial, backoff 1.5, schedule-to-close 60s.

**Acceptance criteria:**
- Running `RunLogActivity` twice for the same `runDate` upserts (not duplicates) the row.
- `started_at` is preserved from the original insert on conflict (not overwritten with the retry's value).
- `completedAt` is set to `Date()` at the time the activity runs.
- `status` is written as the `rawValue` string (`"success"`, `"partial"`, etc.).
