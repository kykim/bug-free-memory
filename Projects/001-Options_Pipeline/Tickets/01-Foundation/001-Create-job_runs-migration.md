# TICKET-001 · Create `job_runs` migration

**File:** `Sources/bug-free-memory/Migrations/CreateJobRuns.swift`

**Task:** Create the `AsyncMigration` that adds the `job_runs` table to the database.

**Schema:**
```
id                UUID        PK
run_date          DATE        NOT NULL
status            VARCHAR     NOT NULL   -- success | partial | failed | skipped
equities_fetched  INT
options_fetched   INT
contracts_priced  INT
theoretical_rows  INT
new_contracts     INT
dropped_positions TEXT[]
failed_tickers    TEXT[]
skipped_contracts TEXT[]
failed_contracts  UUID[]
error_messages    TEXT[]
source_used       VARCHAR
started_at        TIMESTAMP   NOT NULL
completed_at      TIMESTAMP
UNIQUE (run_date)
```

**Acceptance criteria:**
- `CreateJobRuns` compiles as `AsyncMigration`.
- `prepare` creates the schema above.
- `revert` drops the table.
- Migration is registered in `configure.swift` (or wherever existing migrations are registered).
