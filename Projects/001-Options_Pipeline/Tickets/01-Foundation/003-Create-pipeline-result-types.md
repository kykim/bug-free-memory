# TICKET-003 · Create pipeline result types

**Files:**
- `Sources/bug-free-memory/Models/FilteredPositionSet.swift`
- `Sources/bug-free-memory/Models/EODPriceResult.swift`
- `Sources/bug-free-memory/Models/OptionEODResult.swift`
- `Sources/bug-free-memory/Models/PricingResult.swift`
- `Sources/bug-free-memory/Models/RunLogInput.swift`

**Task:** Create all pipeline data-transfer types as `Codable & Sendable` structs.

**Types to implement:**

```swift
// FilteredPositionSet.swift
struct DroppedPosition: Codable, Sendable { let ticker: String; let reason: String }
struct FilteredPositionSet: Codable, Sendable {
    let equityInstrumentIDs: [UUID]
    let optionInstrumentIDs: [UUID]
    let newContractsRegistered: Int
    let droppedPositions: [DroppedPosition]
    let runDate: Date
}

// EODPriceResult.swift
struct EODPriceResult: Codable, Sendable {
    let rowsUpserted: Int; let instrumentsFetched: Int
    let failedTickers: [String]; let source: String
}

// OptionEODResult.swift
struct SkippedContract: Codable, Sendable {
    let instrumentID: UUID; let osiSymbol: String?; let reason: String
}
struct OptionEODResult: Codable, Sendable {
    let contractsProcessed: Int; let rowsUpserted: Int
    let skippedContracts: [SkippedContract]
}

// PricingResult.swift
struct FailedContract: Codable, Sendable { let instrumentID: UUID; let reason: String }
struct PricingResult: Codable, Sendable {
    let contractsPriced: Int; let rowsUpserted: Int
    let failedContracts: [FailedContract]
}

// RunLogInput.swift
enum RunStatus: String, Codable, Sendable { case success, partial, failed, skipped }
struct RunLogInput: Codable, Sendable { ... }  // all activity results + status + timestamps
```

**`RunStatus.determine(...)` static method:**
- `.skipped` if called with explicit `.skipped`.
- `.success` if `errorMessages` is empty.
- `.failed` if `portfolioResult == nil && optionEODResult == nil`.
- `.partial` otherwise.

**Acceptance criteria:**
- All five files compile.
- `RunStatus.determine` returns correct values for all four cases.
- No force-unwraps.
