# TICKET-002 · Create `JobRun` Fluent model

**File:** `Sources/bug-free-memory/Models/JobRun.swift`

**Task:** Create the Fluent `Model` that maps to the `job_runs` table created in TICKET-001.

**Acceptance criteria:**
- `JobRun` is `final class`, conforms to `Model`, `Content`, `@unchecked Sendable`.
- All fields from TICKET-001 are represented with correct Fluent property wrappers (`@ID`, `@Field`, `@OptionalField`).
- Array fields use `[String]` or `[UUID]` as appropriate.
- File compiles cleanly.
