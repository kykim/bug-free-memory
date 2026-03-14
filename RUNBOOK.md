# Feature Development Runbook
## bug-free-memory

This runbook covers the full lifecycle from product idea to merged feature.
Follow each phase in order. Do not proceed to the next phase without completing
the approval gate.

---

## Phase 1 — PRD

**Tool:** claude.ai

1. Describe your product idea to Claude.
2. Claude asks clarifying questions — answer them fully.
3. Claude produces a PRD.
4. Review the PRD. Either:
   - **Approve** — move to Phase 2
   - **Comment** — Claude revises, repeat until approved
5. Save the approved PRD to `docs/prd/<feature-name>.md` in your repo.

---

## Phase 2 — High Level ERD

**Tool:** claude.ai

1. Claude produces a high level ERD based on the approved PRD.
   (Entity names and relationships only — no field-level detail.)
2. Review. Either:
   - **Approve** — move to Phase 3
   - **Comment** — Claude revises, repeat until approved
3. Save the approved ERD to `docs/erd/<feature-name>-high.md`.

---

## Phase 3 — Mid Level ERD

**Tool:** claude.ai

1. Claude expands the high level ERD to include key fields and cardinality.
2. Review. Either:
   - **Approve** — move to Phase 4
   - **Comment** — Claude revises, repeat until approved
3. Save to `docs/erd/<feature-name>-mid.md`.

---

## Phase 4 — Low Level ERD

**Tool:** claude.ai

1. Claude produces a fully detailed ERD: all fields, types, constraints,
   indexes, and Fluent migration notes.
2. Review. Either:
   - **Approve** — move to Phase 5
   - **Comment** — Claude revises, repeat until approved
3. Save to `docs/erd/<feature-name>-low.md`.

---

## Phase 5 — Tickets

**Tool:** claude.ai

1. Claude produces a set of tickets based on the approved low level ERD,
   using the format defined in `tickets/TEMPLATE.md`.
2. Review each ticket for:
   - Clear, testable acceptance criteria
   - Correct test and implementation scope
   - Accurate dependency ordering
3. Either:
   - **Approve** — move to Phase 6
   - **Comment** — Claude revises individual tickets, repeat until approved
4. Save each approved ticket to `tickets/open/TICKET-XXX.md`.

---

## Phase 6 — Create the Feature Branch

**Tool:** Your terminal

This is a manual step. Run these commands before starting Claude Code:

```bash
git checkout main
git pull origin main
git checkout -b feature/<feature-name>
```

Verify the build is clean on the new branch before proceeding:

```bash
swift build
```

If `swift build` fails, fix the issue before continuing. Do not hand a broken
branch to the agents.

---

## Phase 7 — Agent Implementation

**Tool:** Claude Code (in your terminal at the repo root)

Paste the following orchestration prompt into Claude Code, substituting
`<feature-name>` with your actual feature branch name:

```
We're implementing feature/<feature-name>. The feature branch already exists
and swift build is confirmed passing on it. All tickets are in tickets/open/.

Create an agent team with this structure:
- 1 Lead agent (delegate mode only — no implementation)
- 2 Implementer agents
- 1 Reviewer agent

The Lead should:
1. Run the pre-flight check defined in CLAUDE.md before assigning any work.
2. Read all tickets in tickets/open/ and build a dependency-ordered task list.
3. Assign the first wave of unblocked tickets to Implementer agents.
4. As each Implementer finishes, assign the Reviewer to that ticket branch.
5. After the Reviewer approves and merges, assign the next unblocked ticket
   to the freed Implementer.
6. Maintain PROGRESS.md throughout.
7. When tickets/done/ contains all tickets, stop and notify me.

All agents must follow the workflow rules in CLAUDE.md exactly.
```

**While agents are running:**
- Monitor `PROGRESS.md` for status updates.
- If an Implementer is rejected by the Reviewer, the rejection notes will be
  in the ticket file under `tickets/in-review/`. Agents handle the rework
  cycle automatically — no action needed from you unless the Lead escalates.
- Do not run any git commands while agents are active.

---

## Phase 8 — Final Review and Merge

**Tool:** Your terminal + code review tool of choice

When the Lead notifies you that the feature branch is complete:

1. Review the feature branch:
   ```bash
   git checkout feature/<feature-name>
   git diff main
   swift test
   ```
2. Review `tickets/done/` to confirm all tickets are accounted for.
3. Review `PROGRESS.md` for any escalated issues or notes from the Lead.
4. Either:
   - **Approve** — merge to main:
     ```bash
     git checkout main
     git merge feature/<feature-name>
     git push origin main
     ```
   - **Request changes** — open tickets for the issues found, return to Phase 7.

---

## Quick Reference

| Phase | Tool | Output | Gate |
|-------|------|--------|------|
| 1 PRD | claude.ai | `docs/prd/<feature>.md` | Your approval |
| 2 High ERD | claude.ai | `docs/erd/<feature>-high.md` | Your approval |
| 3 Mid ERD | claude.ai | `docs/erd/<feature>-mid.md` | Your approval |
| 4 Low ERD | claude.ai | `docs/erd/<feature>-low.md` | Your approval |
| 5 Tickets | claude.ai | `tickets/open/TICKET-XXX.md` | Your approval |
| 6 Feature branch | Terminal | `feature/<feature>` branch | `swift build` passes |
| 7 Implementation | Claude Code | Merged ticket branches | Lead notification |
| 8 Final review | Terminal | Merged to `main` | Your approval |
