# TICKET-016 · Register Temporal worker in `configure.swift`

**Task:** Add Temporal worker startup to `configure.swift` (or the appropriate app bootstrap file).

**Depends on:** TICKET-015.

**Requirements:**
- Connect `TemporalClient` to `localhost:7233`, namespace `"default"`.
- Register `DailyPipelineWorkflow` and all five activities on task queue `"daily-pipeline"`.
- Wrap the worker in a `TemporalWorkerLifecycle` and register with `app.lifecycle`.
- Worker startup must not block the Vapor app from starting.

**Acceptance criteria:**
- `vapor run` starts the Temporal worker alongside the HTTP server.
- No crash on startup if Temporal server is not running (log warning, degrade gracefully).
- Task queue name is `"daily-pipeline"` (not hardcoded in multiple places — define as a constant).
