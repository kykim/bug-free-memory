# TICKET-004 · Implement `OSIParser`

**File:** `Sources/bug-free-memory/Extensions/OSIParser.swift`

**Task:** Implement OSI symbol parser and supporting types.

**OSI format:** 21-character string. Characters 0–5: underlying ticker (right-padded with spaces). Characters 6–11: expiry `YYMMDD`. Character 12: `C` or `P`. Characters 13–20: strike × 1000, zero-padded to 8 digits.

**Types:**
```swift
enum OSIParseError: Error { case invalidLength(actual: Int); case invalidExpiryFormat(String); case invalidOptionType(Character); case invalidStrike(String) }
struct OSIComponents { let underlyingTicker: String; let expirationDate: Date; let optionType: OptionType; let strikePrice: Double }
enum OSIParser { static func parse(_ osi: String) throws -> OSIComponents }
```

**Acceptance criteria:**
- `OSIParser.parse("AAPL  260321C00175000")` returns `underlyingTicker: "AAPL"`, `optionType: .call`, `strikePrice: 175.0`, `expirationDate: 2026-03-21`.
- `OSIParser.parse("SPY   260620P00450000")` returns `underlyingTicker: "SPY"`, `optionType: .put`, `strikePrice: 450.0`.
- Strings shorter or longer than 21 chars throw `invalidLength`.
- Invalid expiry throws `invalidExpiryFormat`.
- Invalid option type char throws `invalidOptionType`.
- Non-numeric strike throws `invalidStrike`.
- `DateFormatter` uses timezone `America/New_York`.
