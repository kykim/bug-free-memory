# bug-free-memory — Agent Operating Manual

## Stack
- Swift / Vapor 4
- PostgreSQL via Fluent ORM
- Leaf templating
- ClerkVapor authentication
- Hosted on Render

## Branching Model
- `main` — production, never touched by agents
- `feature/<feature-name>` — the feature branch; created by the human before
  agents are started; agents merge ticket branches INTO this
- `ticket/<ticket-id>` — per-ticket branch, branched FROM the feature branch

## Pre-flight Check (Lead agent must verify before assigning any work)
Before spawning Implementer agents, the Lead must confirm:
1. The feature branch exists: `git branch --list feature/<FEATURE>`
   If it does NOT exist, stop immediately and message the human:
   "Feature branch feature/<FEATURE> does not exist. Please create it from
   main and re-run the orchestration prompt."
2. All tickets are present in `tickets/open/`
3. `swift build` passes on the feature branch before any ticket work begins

## Workflow Rules (ALL agents must follow these)

### For Implementer agents:
1. Confirm you are on the correct ticket branch:
   `git checkout ticket/<TICKET-ID>`
   If the branch doesn't exist:
   `git checkout -b ticket/<TICKET-ID> feature/<FEATURE>`
2. Move the ticket file: `mv tickets/open/TICKET-XXX.md tickets/in-progress/`
3. **Write tests FIRST.** No implementation code until the test file exists and
   the tests are confirmed to fail (`swift test` should fail at this stage).
4. Implement until `swift test` passes for your ticket's scope.
5. Move the ticket file: `mv tickets/in-progress/TICKET-XXX.md tickets/in-review/`
6. Message the Reviewer agent: "TICKET-XXX ready for review on branch ticket/TICKET-XXX"
7. Do NOT merge your branch.

### For Reviewer agents:
1. Check out the ticket branch: `git checkout ticket/<TICKET-ID>`
2. Run `swift build` — must succeed with zero errors.
3. Run `swift test` — all tests must pass, including new ones.
4. Review the diff against `feature/<FEATURE>` for:
   - Tests written before implementation (check git log order)
   - Fluent model correctness and migration safety
   - No force-unwraps without justification
   - Clerk auth middleware applied where required
   - No hardcoded secrets or credentials
5. If approved: merge `ticket/<TICKET-ID>` into `feature/<FEATURE>` and move
   ticket to `tickets/done/`
6. If rejected: leave ticket in `tickets/in-review/`, add a REVIEW_NOTES.md to
   the ticket with specific issues, message the Implementer directly.

### For the Lead agent:
- Operate in delegate mode — coordinate, do not implement.
- Verify the pre-flight check passes before assigning any tickets.
- Maintain a PROGRESS.md at repo root with ticket status summary.
- When all tickets are in `tickets/done/`, message the human:
  "Feature branch feature/<FEATURE> is complete and ready for your review."
- Do NOT merge the feature branch into main.

## Code Conventions
- Models go in `Sources/hello/Models/`
- Routes go in `Sources/hello/Routes/`
- Tests go in `Tests/helloTests/`
- Test file naming: `<Model>Tests.swift` or `<Feature>Tests.swift`
- Use `XCTAssertEqual`, `XCTAssertNotNil` — no custom test frameworks
- All database operations through Fluent — no raw SQL
- Risk-free rate interpolation follows the FRED yield curve pattern
  already established in the codebase

## What agents must NEVER do
- Merge any branch into `main`
- Push to any remote (`git push` is denied)
- Delete branches
- Modify `CLAUDE.md`, `.claude/settings.json`, or any ticket in `tickets/done/`
- Use `--force` on any git command
