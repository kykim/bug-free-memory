# TICKET-007 · Implement `OptionContractRegistrar`

**File:** `Sources/bug-free-memory/Extensions/OptionContractRegistrar.swift`

**Task:** Implement the helper that creates a new `Instrument` + `OptionContract` row pair for a newly encountered option position.

```swift
enum OptionContractRegistrar {
    static func register(
        osi: OSIComponents, osiSymbol: String,
        underlyingInstrument: Instrument, db: Database
    ) async throws -> UUID
}
```

**Logic:**
1. Check for existing `Instrument` with `ticker == osiSymbol`. If found, return its `id` immediately (idempotent re-entry).
2. Derive `instrumentType` (`.equityOption` vs `.indexOption`), `exerciseStyle` (`.american` vs `.european`), `settlementType` (`"physical"` vs `"cash"`) from whether `underlyingInstrument.instrumentType == .index`.
3. Create and save `Instrument` row.
4. On `PSQLError.uniqueViolation` (lost race), fetch and return the existing instrument's `id`.
5. Create and save `OptionContract` row with `contractMultiplier: 100`.
6. Return new `instrument.id`.

**Acceptance criteria:**
- Calling `register` twice with the same `osiSymbol` returns the same UUID both times without throwing.
- `exerciseStyle` is `.european` when underlying `instrumentType == .index`.
- `exerciseStyle` is `.american` when underlying `instrumentType == .equity`.
- `contractMultiplier` is always set to `100`.
- File compiles cleanly.
