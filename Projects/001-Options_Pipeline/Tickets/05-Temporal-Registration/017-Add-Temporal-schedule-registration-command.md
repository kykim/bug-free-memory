# TICKET-017 · Add Temporal schedule registration command

**Task:** Create a Vapor `Command` (or standalone Swift script) to register the Temporal cron schedule. This is a one-time setup command, not run on every startup.

**Schedule spec:**
- Cron: `0 16 * * 1-5`
- Timezone: `America/New_York`
- Workflow: `DailyPipelineWorkflow`
- Workflow ID pattern: `daily-pipeline-YYYYMMDD` (using `DateFormatter` with `yyyyMMdd` format and `America/New_York` timezone)
- Schedule ID: `"daily-pipeline-schedule"`

**Acceptance criteria:**
- Running the command once registers the schedule in Temporal.
- Running it a second time does not throw — handle `ScheduleAlreadyExistsError` gracefully (log and exit cleanly).
- Workflow ID is scoped to the run date, preventing duplicate executions for the same calendar day.
