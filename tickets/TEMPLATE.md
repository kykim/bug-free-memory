# TICKET-XXX: <Title>

## Status
open | in-progress | in-review | done

## Branch
ticket/TICKET-XXX (branch from: feature/<FEATURE>)

## Context
<Link to relevant ERD section or design doc>

## Acceptance Criteria
- [ ] <Specific, testable criterion>
- [ ] <Specific, testable criterion>
- [ ] All new tests pass (`swift test`)
- [ ] No regressions in existing tests

## Test Scope
Files that MUST have test coverage:
- `Tests/bug-free-memoryTests/<File>.swift`

## Implementation Scope
Files expected to be modified:
- `Sources/bug-free-memory/<Path>`

## Dependencies
Blocked by: TICKET-XXX (or "none")
```

The explicit **Test Scope** and **Implementation Scope** sections are important — they give implementer agents a bounded context window footprint and keep them from wandering the codebase.

---

### 5. The Orchestration Prompt

Once tickets are written and approved, you kick off the implementation phase with a single prompt to Claude Code:
```
We're implementing feature/<FEATURE-NAME>. The feature branch already exists.
All tickets are in tickets/open/.

Create an agent team with this structure:
- 1 Lead agent (delegate mode only — no implementation)
- 2 Implementer agents
- 1 Reviewer agent

The Lead should:
1. Read all tickets in tickets/open/ and build a dependency-ordered task list
2. Assign the first wave of unblocked tickets to Implementer agents
3. As each Implementer finishes, assign the Reviewer to that ticket
4. After Reviewer approves and merges, assign the next unblocked ticket to the
   freed Implementer
5. Maintain PROGRESS.md throughout
6. When tickets/done/ contains all tickets, stop and notify me

All agents must follow the workflow rules in CLAUDE.md exactly.
```

---

### How the full pipeline connects
```
You (claude.ai)                     Claude Code (your terminal)
─────────────────────────────────   ──────────────────────────────────────
Prompt product idea
  → PRD (approve/comment)
  → High ERD (approve/comment)
  → Mid ERD (approve/comment)
  → Low ERD (approve/comment)
  → Tickets written + approved
                                    Copy tickets to tickets/open/
                                    git checkout -b feature/<name>
                                    Paste orchestration prompt
                                         ↓
                                    Lead spawns Implementers + Reviewer
                                    Implementers: test → implement → review-queue
                                    Reviewer: checks tests, merges to feature branch
                                    Cycle repeats per ticket
                                         ↓
                                    Lead: "Feature branch ready for your review"
You: review feature branch
  → merge to main (your call)
