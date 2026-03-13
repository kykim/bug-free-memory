# TICKET-010 · Implement `PortfolioActivity`

**File:** `Sources/bug-free-memory/Activities/PortfolioActivity.swift`

**Task:** Implement the Temporal activity that downloads Schwab positions and returns a `FilteredPositionSet`.

**Depends on:** TICKET-003, TICKET-004, TICKET-007, TICKET-008.

**Logic (in order):**
1. Call `schwabClient.refreshTokenIfNeeded(db:)`.
2. Call `schwabClient.fetchPortfolioPositions()`.
3. Partition into `equityPositions`, `optionPositions`, and `other` (drop `other` with reason `"unsupported_asset_type"`).
4. For each equity position: query `Instrument` joined to `Equity` by ticker. Append `instrument.id` to `equityInstrumentIDs` if found, else append `DroppedPosition(reason: "not_in_equities")`.
5. For each option position: parse OSI symbol. On parse error, append `DroppedPosition(reason: "osi_parse_error")` and continue. Look up underlying ticker in `instruments JOIN equities`. If not found, append `DroppedPosition(reason: "underlying_not_in_equities")` and continue. Check `option_contracts` for existing row by `osi_symbol`. If exists, append existing `instrument_id`. If not, call `OptionContractRegistrar.register(...)`, append new `instrument_id`, increment `newContractsRegistered`. Wrap registration in `do/catch` — log error and continue on failure.
6. Return `FilteredPositionSet`.

**Retry policy:** 3 attempts, 30s initial interval, backoff 2.0, schedule-to-close 300s.

**Logging:** `.info` on start (with `runDate`) and complete (with duration, counts). `.warning` per dropped position. `.error` per registration failure.

**Acceptance criteria:**
- Positions with unsupported asset types appear in `droppedPositions` with reason `"unsupported_asset_type"`.
- A bad OSI symbol appears in `droppedPositions` with reason `"osi_parse_error"` and does not throw.
- A registration failure logs an error but does not fail the activity.
- Retry policy is set as specified.
