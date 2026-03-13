# TICKET-008 · Add `SchwabPosition` and `fetchPortfolioPositions()` to Schwab client

**File:** `Sources/bug-free-memory/Extensions/SchwabClient+Portfolio.swift`

**Task:** Extend the existing `SchwabClient` with portfolio position fetching.

**Types:**
```swift
enum SchwabAssetType: String, Codable { case equity = "EQUITY"; case option = "OPTION"; case other }
struct SchwabPosition: Codable { let ticker: String; let assetType: SchwabAssetType; let quantity: Double; let osiSymbol: String?; let marketValue: Double? }
```

**Method:**
```swift
extension SchwabClient {
    func fetchPortfolioPositions() async throws -> [SchwabPosition]
    func refreshTokenIfNeeded(db: Database) async throws
}
```

**`fetchPortfolioPositions`:** `GET /trader/v1/accounts/{accountNumber}/positions`. Decode response as `[SchwabPosition]`.

**`refreshTokenIfNeeded`:** Query `oauth_tokens WHERE provider = "schwab"`. If `isExpired(buffer: 60)` is true, call existing `refreshToken(refreshToken:)` and persist updated token. Throw `SchwabError.noTokenFound` if no token row exists.

**`SchwabAssetType` decoding:** Unknown values map to `.other` (custom `init(from:)` decoder).

**Acceptance criteria:**
- `SchwabAssetType(rawValue: "EQUITY")` == `.equity`.
- Unknown asset type string decodes as `.other` without throwing.
- `refreshTokenIfNeeded` saves the refreshed token back to `oauth_tokens`.
- File compiles against existing `SchwabClient` without modifying it.
