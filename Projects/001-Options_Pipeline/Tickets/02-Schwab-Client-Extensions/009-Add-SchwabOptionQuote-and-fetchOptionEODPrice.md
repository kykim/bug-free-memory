# TICKET-009 · Add `SchwabOptionQuote` and `fetchOptionEODPrice()` to Schwab client

**File:** `Sources/bug-free-memory/Extensions/SchwabClient+OptionQuote.swift`

**Task:** Extend `SchwabClient` with single-contract option quote fetching.

**Type:**
```swift
struct SchwabOptionQuote: Codable {
    let bid: Double?; let ask: Double?; let last: Double?
    let volume: Int?; let openInterest: Int?
    let impliedVolatility: Double?; let underlyingPrice: Double?
    let delta: Double?; let gamma: Double?; let theta: Double?; let vega: Double?; let rho: Double?
}
```

**CodingKeys:** `impliedVolatility` maps to `"volatility"`. All others are identity.

**Method:**
```swift
extension SchwabClient {
    func fetchOptionEODPrice(osiSymbol: String) async throws -> SchwabOptionQuote?
}
```

Endpoint: `GET /marketdata/v1/quotes?symbols={osiSymbol}`. Response is `[String: SchwabOptionQuote]`. Return `decoded[osiSymbol]` (may be `nil` for unknown symbols).

**Acceptance criteria:**
- `SchwabOptionQuote` decodes `"volatility"` JSON key into `impliedVolatility` property.
- Returns `nil` (not throw) when the symbol is absent from the response dictionary.
- Throws `SchwabError.authFailure` on 401 responses (propagate from existing client error handling).
- File compiles against existing `SchwabClient`.
