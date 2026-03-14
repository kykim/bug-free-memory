# Low-Level ERD — Code Review Security & Reliability Hardening

> Generated 2026-03-14 from code review `Projects/002-Code_Review/Code_Review.md`
> Builds on `Code_Review-mid.md`. Covers: exact before/after code for every
> issue, new files to create, AppError extensions, and dependency ordering.

---

## Correction to Mid-Level ERD

The mid-ERD incorrectly listed five unique constraints as missing. Reading the
actual migration files shows all of them are already present:

| Table | Constraint | Migration file |
|---|---|---|
| `oauth_tokens` | `UNIQUE(clerk_user_id, provider)` | `CreateOAuthToken.swift:24` |
| `eod_prices` | `UNIQUE(instrument_id, price_date)` | `CreateEODPrices.swift:28` |
| `option_eod_prices` | `UNIQUE(instrument_id, price_date)` | `CreateOptionEODPrices.swift:37` |
| `theoretical_option_eod_prices` | `UNIQUE(instrument_id, price_date, model)` | `CreateTheoreticalOptionEODPrice.swift:42` |
| `fred_yields` | `UNIQUE(series_id, observation_date)` | `CreateFREDYield.swift:34` |

Additionally, Issue #7's third `SchwabTokenResponse` instance
(`SchwabController.swift` local struct) is no longer present in the codebase —
it was removed in commit `eecc6f6`. Two divergent definitions remain:
`routes.swift` and `SchwabClient.swift`.

**No new migrations are required for this code review.** All DB-layer fixes
are application-code changes only.

---

## Dependency Order

Fix these in the following sequence to avoid broken intermediary states:

```
#7  (canonical SchwabTokenResponse)  ← unblocks #5 (one place to fix encoding)
#10 (CLERK_SECRET_KEY guard)          ← unblocks nothing, standalone
#11 (parsedInstrumentType throws)     ← unblocks #13 (can simplify after)
#2  (clerkUserId in refreshToken)     ← unblocks #18 (routes.swift refresh route)
#5  (percent-encode tokens)           ← after #7 and #2 are done
#4  (race condition)                  ← after #2 (shares the same function)
#1  (OAuth state CSRF)                ← after #15 (add auth first, then state)
#15 (add auth to /schwab/login)       ← standalone prerequisite for #1
#3  (remove token from Leaf context)  ← standalone
#6  (Date() determinism)              ← standalone
#8  (remove autoMigrate)              ← standalone; coordinate with deploy process
#9  (unsafeRaw filter)                ← standalone
#12 (model.id! force-unwraps)         ← standalone; add extension first
#13 (double body decode)              ← after #11
#14 (memory sessions)                 ← standalone; requires infra decision
#16 (Temporal storage)                ← standalone
#17 (greet blocks)                    ← standalone; low priority
#18 (duplicate refresh logic)         ← after #2 and #5
#19 (connection pool)                 ← standalone; tune after load test
```

---

## Issue #1 — Add OAuth `state` Parameter (CSRF)

**Files:** `Sources/bug-free-memory/routes.swift`, `Sources/bug-free-memory/AppError.swift`

**AppError.swift** — add two cases:
```swift
// Before: no state-related cases

// After:
case oauthStateMissing      // callback arrived without state param
case oauthStateInvalid      // state param doesn't match session value

// In var status:
case .oauthStateMissing, .oauthStateInvalid:
    return .forbidden

// In var reason:
case .oauthStateMissing:
    return "OAuth state parameter missing from callback"
case .oauthStateInvalid:
    return "OAuth state parameter does not match session"
```

**routes.swift — login handler:**
```swift
// Before (line 86–98):
app.get("schwab", "login") { req -> Response in
    let clientID = Environment.get("SCHWAB_CLIENT_ID") ?? ""
    let redirectURI = Environment.get("SCHWAB_REDIRECT_URI") ?? "..."
    var components = URLComponents(string: "https://api.schwabapi.com/v1/oauth/authorize")!
    components.queryItems = [
        .init(name: "response_type", value: "code"),
        .init(name: "client_id", value: clientID),
        .init(name: "redirect_uri", value: redirectURI),
    ]
    return req.redirect(to: components.url!.absoluteString, redirectType: .temporary)
}

// After:
app.grouped(ClerkMiddleware(), ClerkAuthMiddleware()).get("schwab", "login") { req -> Response in
    let state = UUID().uuidString
    req.session.data["oauthState"] = state
    let clientID = Environment.get("SCHWAB_CLIENT_ID") ?? ""
    let redirectURI = Environment.get("SCHWAB_REDIRECT_URI") ?? "..."
    var components = URLComponents(string: "https://api.schwabapi.com/v1/oauth/authorize")!
    components.queryItems = [
        .init(name: "response_type", value: "code"),
        .init(name: "client_id", value: clientID),
        .init(name: "redirect_uri", value: redirectURI),
        .init(name: "state", value: state),
    ]
    return req.redirect(to: components.url!.absoluteString, redirectType: .temporary)
}
```

**routes.swift — callback handler** (add state verification after `guard let code`):
```swift
// After extracting code, add immediately:
guard let receivedState = req.query[String.self, at: "state"] else {
    throw AppError.oauthStateMissing
}
guard let sessionState = req.session.data["oauthState"],
      receivedState == sessionState else {
    throw AppError.oauthStateInvalid
}
req.session.data["oauthState"] = nil   // consume — single use
```

**Test file:** `Tests/bug-free-memoryTests/SchwabOAuthTests.swift` (new)
```swift
// testCallbackMissingStateReturns403()
// testCallbackWrongStateReturns403()
// testCallbackCorrectStateProceedsToTokenExchange()
// testLoginResponseContainsStateQueryParam()
// testLoginRouteRequiresAuthentication()  (unauthenticated → 401)
```

---

## Issue #2 — `refreshTokenIfNeeded` Missing `clerkUserId` Filter

**Files:** `Sources/bug-free-memory/Extensions/SchwabClient+Portfolio.swift`,
`Sources/bug-free-memory/Activities/PortfolioActivity.swift`,
`Sources/bug-free-memory/Controllers/IndexController.swift`,
`Sources/bug-free-memory/Controllers/SchwabController.swift`

**SchwabClient+Portfolio.swift** — change signature and filter:
```swift
// Before (line 97–100):
func refreshTokenIfNeeded(db: any Database) async throws {
    guard let tokenRow = try await OAuthToken.query(on: db)
        .filter(\.$provider == "schwab")
        .first() else {

// After:
func refreshTokenIfNeeded(db: any Database, clerkUserId: String) async throws {
    guard let tokenRow = try await OAuthToken.query(on: db)
        .filter(\.$clerkUserId == clerkUserId)
        .filter(\.$provider == "schwab")
        .first() else {
```

**PortfolioActivity.swift** — `clerkUserId` must be threaded in.
The cleanest approach given the current design is to add it to
`DailyPipelineInput` (pipeline is single-user today) and pass it down through
the activity container:

```swift
// DailyPipelineInput — add field:
public struct DailyPipelineInput: Codable, Sendable {
    public let runDate: Date
    public let isHoliday: Bool
    public let startedAt: Date    // see Issue #6
    public let clerkUserId: String
}

// PortfolioActivities init — add field:
init(db: any Database, schwabClient: SchwabClient, clerkUserId: String, logger: Logger)

// fetchPortfolioPositions — pass through:
try await schwabClient.refreshTokenIfNeeded(db: db, clerkUserId: clerkUserId)
```

**IndexController.swift** — `fetchToday` and `backfill` call sites:
```swift
// Both call sites currently:
try await schwab.refreshTokenIfNeeded(db: req.db)

// After (userId is force-unwrapped here — acceptable since ClerkAuthMiddleware
// already enforces authentication at this route level):
let userId = req.clerkAuth.userId!
try await schwab.refreshTokenIfNeeded(db: req.db, clerkUserId: userId)
```

**SchwabController.swift** — `portfolio()`:
```swift
// Before:
try await schwabClient.refreshTokenIfNeeded(db: req.db)

// After:
let userId = req.clerkAuth.userId!
try await schwabClient.refreshTokenIfNeeded(db: req.db, clerkUserId: userId)
```

**Test file:** `Tests/bug-free-memoryTests/SchwabClientTests.swift` (extend existing)
```swift
// testRefreshTokenIfNeededFiltersToCorrectUser()
//   — seed two oauth_token rows (different clerk_user_id, same provider)
//   — call refreshTokenIfNeeded(db:clerkUserId: userA)
//   — assert only userA's token was read
// testRefreshTokenIfNeededThrowsForUnknownUser()
```

---

## Issue #3 — Decrypted Access Token in Leaf Context

**File:** `Sources/bug-free-memory/routes.swift`

```swift
// Before — Context struct (line 49–57):
struct Context: Encodable {
    var appName: String
    var pageTitle: String
    var schwabConnected: Bool
    var schwabHasRefreshToken: Bool
    var schwabTokenExpiresAt: String?
    var schwabRefreshTokenExpiresAt: String?
    var schwabAccessToken: String?    // ← remove
}

// Before — body (lines 68–82):
var schwabAccessToken: String? = nil
if let token = schwabToken, refreshTokenValid {
    let key = try req.application.requireTokenEncryptionKey()
    schwabAccessToken = try TokenEncryption.decrypt(token.accessToken, key: key)
}
// ...
schwabAccessToken: schwabAccessToken    // ← remove from Context(...) call

// After: delete the schwabAccessToken variable, the decrypt block, and the
// Context field entirely. Update dashboard.leaf to remove any reference to
// schwabAccessToken.
```

**Test file:** `Tests/bug-free-memoryTests/DashboardTests.swift` (new or extend)
```swift
// testDashboardContextDoesNotContainAccessToken()
//   — authenticated request to GET /dashboard
//   — assert response body does not contain the literal access token value
```

---

## Issue #4 — Concurrent Token Refresh Race Condition

**File:** `Sources/bug-free-memory/Extensions/SchwabClient+Portfolio.swift`

The `SchwabClient` is `final class @unchecked Sendable` stored on `Application`.
The correct fix is a `NSLock` (or Swift `actor`) around the fetch-check-refresh
sequence, since `SchwabClient` already lives for the duration of the app.

```swift
// Add to SchwabClient.swift — new stored property:
private let refreshLock = NSLock()

// SchwabClient+Portfolio.swift — wrap the expiry check + refresh:
func refreshTokenIfNeeded(db: any Database, clerkUserId: String) async throws {
    // Serialize: only one refresh call at a time per SchwabClient instance.
    // NSLock.withLock is synchronous; use a task-based approach if contention
    // becomes a bottleneck.
    try await withCheckedThrowingContinuation { continuation in
        refreshLock.withLock {
            // Re-check expiry inside the lock to handle the TOCTOU window.
            Task {
                do {
                    guard let tokenRow = try await OAuthToken.query(on: db)
                        .filter(\.$clerkUserId == clerkUserId)
                        .filter(\.$provider == "schwab")
                        .first() else {
                        continuation.resume(throwing: SchwabError.noTokenFound)
                        return
                    }
                    if tokenRow.isExpired(buffer: 60) {
                        // ... refresh logic (unchanged) ...
                    } else {
                        let plainAccess = try TokenEncryption.decrypt(
                            tokenRow.accessToken, key: encryptionKey)
                        self.accessToken = plainAccess
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
```

> **Note:** If `SchwabClient` is later converted to a Swift `actor`, replace
> `NSLock` with actor isolation — the actor's executor provides the same
> serialization guarantee without the lock.

**Test file:** `Tests/bug-free-memoryTests/SchwabClientTests.swift`
```swift
// testConcurrentRefreshCallsOnlyRefreshOnce()
//   — mock URLSession to record call count
//   — fire two concurrent refreshTokenIfNeeded calls against an expired token
//   — assert Schwab token endpoint called exactly once
```

---

## Issue #5 — Refresh Token Not URL-Percent-Encoded

**Files:** `Sources/bug-free-memory/routes.swift` (lines 119, 174),
`Sources/bug-free-memory/Services/SchwabClient.swift` (line 90)

```swift
// Helper to add once (e.g. in Extensions.swift or inline):
extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

// routes.swift line 119 — authorization_code exchange:
// Before:
r.body = .init(string: "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI)")
// After:
r.body = .init(string: "grant_type=authorization_code&code=\(code.urlFormEncoded)&redirect_uri=\(redirectURI.urlFormEncoded)")

// routes.swift line 174 — manual refresh route:
// Before:
r.body = .init(string: "grant_type=refresh_token&refresh_token=\(refreshToken)")
// After:
r.body = .init(string: "grant_type=refresh_token&refresh_token=\(refreshToken.urlFormEncoded)")

// SchwabClient.swift line 90 — SchwabClient.refreshToken():
// Before:
let body = "grant_type=refresh_token&refresh_token=\(refreshToken)"
// After:
let body = "grant_type=refresh_token&refresh_token=\(refreshToken.urlFormEncoded)"
```

**Test file:** `Tests/bug-free-memoryTests/SchwabClientTests.swift`
```swift
// testRefreshTokenWithSpecialCharsIsPercentEncoded()
//   — call refreshToken(refreshToken: "abc+def=ghi/jkl")
//   — assert URLRequest body contains "abc%2Bdef%3Dghi%2Fjkl" (or equivalent)
//   — mock URLSession to capture the outgoing request body
```

---

## Issue #6 — `Date()` Violates Temporal Determinism

**Files:** `Sources/bug-free-memory/Workflows/DailyPipelineWorkflow.swift`,
`Sources/bug-free-memory/Models/RunLogInput.swift`,
`Sources/bug-free-memory/Workers/DailyPipelineWorker.swift` (or wherever
`DailyPipelineInput` is constructed for dispatch)

**DailyPipelineInput** — add `startedAt`:
```swift
// Before:
public struct DailyPipelineInput: Codable, Sendable {
    public let runDate: Date
    public let isHoliday: Bool
}

// After:
public struct DailyPipelineInput: Codable, Sendable {
    public let runDate: Date
    public let isHoliday: Bool
    public let startedAt: Date     // set by caller before dispatch; replay-safe
    public let clerkUserId: String  // also added for Issue #2
}
```

**DailyPipelineWorkflow.swift** — replace `Date()` references:
```swift
// Before (line 28):
let startedAt = Date()

// After: remove this line entirely; use input.startedAt instead.

// Before (line 54 — skip path):
completedAt: Date()

// After: no inline Date() is replay-safe. Use a Temporal side-effect or
// accept that completedAt for a skip is approximately startedAt:
completedAt: input.startedAt   // skip completes instantly; startedAt is close enough

// Before (line 167 — normal completion):
completedAt: Date()

// After: have RunLogActivity record its own wall-clock time internally
// (activities are NOT required to be deterministic), OR accept the
// timestamp returned from the last completed activity.
// Simplest correct fix: move completedAt into RunLogActivity itself:
//   RunLogInput drops completedAt
//   RunLogActivity writes JobRun with completedAt = Date() inside the activity
```

**Call site** (wherever `DailyPipelineInput` is constructed):
```swift
// Before:
DailyPipelineInput(runDate: runDate, isHoliday: isHoliday)

// After:
DailyPipelineInput(
    runDate: runDate,
    isHoliday: isHoliday,
    startedAt: Date(),      // fine here — this is outside the workflow
    clerkUserId: clerkUserId
)
```

**Test file:** `Tests/bug-free-memoryTests/DailyPipelineWorkflowTests.swift` (extend existing)
```swift
// testWorkflowDoesNotCallDateDirectly()
//   — inspect workflow source; this is a static analysis test:
//     assert "Date()" does not appear in DailyPipelineWorkflow.swift
// testStartedAtFromInputIsUsedInRunLog()
//   — provide a known startedAt in DailyPipelineInput
//   — assert JobRun.startedAt == input.startedAt
```

---

## Issue #7 — Consolidate `SchwabTokenResponse`

**New file:** `Sources/bug-free-memory/Models/SchwabTokenResponse.swift`
```swift
// NEW FILE — canonical definition
struct SchwabTokenResponse: Content {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case idToken      = "id_token"
        case tokenType    = "token_type"
        case expiresIn    = "expires_in"
    }
}
```

**routes.swift** — remove the module-level `SchwabTokenResponse` struct
(lines 5–19). The type is now resolved from `SchwabTokenResponse.swift`.

**SchwabClient.swift** — replace the private `SchwabOAuthTokenResponse`:
```swift
// Before (lines 29–33):
private struct SchwabOAuthTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}

// After: delete this struct. Update refreshToken() to use the canonical type:
// Before (line 103):
let tokenResponse = try JSONDecoder().decode(SchwabOAuthTokenResponse.self, from: data)
return (tokenResponse.access_token, tokenResponse.refresh_token, tokenResponse.expires_in)

// After:
let tokenResponse = try JSONDecoder().decode(SchwabTokenResponse.self, from: data)
return (tokenResponse.accessToken, tokenResponse.refreshToken, tokenResponse.expiresIn)
```

**Test file:** `Tests/bug-free-memoryTests/SchwabClientTests.swift`
```swift
// testSchwabTokenResponseDecodesAllFields()
//   — JSON with access_token, refresh_token, id_token, token_type, expires_in
//   — assert all fields decoded correctly by canonical SchwabTokenResponse
// testSchwabTokenResponseHandlesMissingOptionalFields()
//   — JSON without refresh_token, id_token
//   — assert decodes without error; optional fields are nil
```

---

## Issue #8 — Remove `autoMigrate()` from Startup

**File:** `Sources/bug-free-memory/configure.swift`

```swift
// Before (line 70):
try await app.autoMigrate()

// After: remove this line entirely.
```

**Render deploy command** (outside codebase — update via Render dashboard):
```
# Pre-deploy (before new instance starts):
swift run App migrate --yes

# Start command (unchanged):
swift run App serve --hostname 0.0.0.0 --port $PORT
```

**docker-compose.yml** — add a `migrate` service alongside `app` and `worker`:
```yaml
  migrate:
    image: bug-free-memory:latest
    build:
      context: .
    environment:
      <<: *shared_environment
    depends_on:
      db:
        condition: service_healthy
    command: ["migrate", "--yes", "--env", "production"]
    # One-shot service — exits 0 on success, non-zero on failure.
    # Default restart policy is "no", so Compose will not restart it.
```

Run migrations before starting the app:
```
# --rm removes the stopped container after exit (avoids accumulating
# leftover containers from repeated migration runs)
docker compose run --rm migrate
docker compose up app worker
```

Or as a single sequenced command:
```
docker compose run --rm migrate && docker compose up app worker
```

> The `migrate` service intentionally has no `ports` and no `restart` policy.
> Do not add `migrate` to the `depends_on` of `app` or `worker` — migration
> is an operator-run pre-flight step. A failed migration should not silently
> allow the app to start against a stale schema.

> If running locally without Docker:
> `swift run App migrate --yes`

No test required for this change. The absence of `autoMigrate()` is verified
by code review.

---

## Issue #9 — Replace `unsafeRaw` SQL Filter

**File:** `Sources/bug-free-memory/Controllers/IndexController.swift`

```swift
// Before (line 23):
async let instruments = Instrument.query(on: req.db)
    .filter(.sql(unsafeRaw: "\"instrument_type\" = 'index'::instrument_type"))
    .sort(\.$ticker).all()

// After:
async let instruments = Instrument.query(on: req.db)
    .filter(\.$instrumentType == .index)
    .sort(\.$ticker).all()
```

**Test file:** `Tests/bug-free-memoryTests/IndexControllerTests.swift` (new or extend)
```swift
// testIndexListOnlyReturnsIndexInstruments()
//   — seed instruments with types: equity, index, equity_option
//   — GET /indexes
//   — assert only index-type instruments appear in response
```

---

## Issue #10 — Guard on `CLERK_SECRET_KEY`

**Files:** `Sources/bug-free-memory/configure.swift`,
`Sources/bug-free-memory/AppError.swift`

**AppError.swift** — add case:
```swift
case missingEnvironmentVariable(String)

// In var status:
case .missingEnvironmentVariable:
    return .internalServerError

// In var reason:
case .missingEnvironmentVariable(let name):
    return "Required environment variable '\(name)' is not set"
```

**configure.swift:**
```swift
// Before (line 73):
app.useClerk(ClerkConfiguration(
    secretKey: Environment.get("CLERK_SECRET_KEY")!,
    ...
))

// After:
guard let clerkSecretKey = Environment.get("CLERK_SECRET_KEY") else {
    throw AppError.missingEnvironmentVariable("CLERK_SECRET_KEY")
}
app.useClerk(ClerkConfiguration(
    secretKey: clerkSecretKey,
    ...
))
```

**Test file:** `Tests/bug-free-memoryTests/ConfigureTests.swift` (new)
```swift
// testMissingClerkSecretKeyThrowsDescriptiveError()
//   — call configure() with CLERK_SECRET_KEY unset
//   — assert throws AppError.missingEnvironmentVariable("CLERK_SECRET_KEY")
//   — assert does NOT crash the process (i.e. is a thrown error, not a trap)
```

---

## Issue #11 — `parsedInstrumentType` Force-Unwrap

**File:** `Sources/bug-free-memory/DTOs/InstrumentDTOs.swift`

```swift
// Before (line 34):
var parsedInstrumentType: InstrumentType { InstrumentType(rawValue: instrument_type)! }

// After:
func parsedInstrumentType() throws -> InstrumentType {
    guard let type = InstrumentType(rawValue: instrument_type) else {
        throw Abort(.unprocessableEntity,
                    reason: "Invalid instrument_type '\(instrument_type)'")
    }
    return type
}
```

**InstrumentController.swift** — update call site:
```swift
// Before (create, line 61):
instrumentType: input.parsedInstrumentType,

// After:
instrumentType: try input.parsedInstrumentType(),
```

**Test file:** `Tests/bug-free-memoryTests/InstrumentDTOTests.swift` (new)
```swift
// testParsedInstrumentTypeSucceedsForValidRawValues()
//   — all four valid strings return correct InstrumentType
// testParsedInstrumentTypeThrowsForInvalidRawValue()
//   — "invalid_type" throws Abort(.unprocessableEntity)
//   — does NOT trap/crash
```

---

## Issue #12 — Pervasive `model.id!` Force-Unwraps

**New extension** — add to `Sources/bug-free-memory/Extensions.swift`
(or a new `Sources/bug-free-memory/Extensions/ModelExtensions.swift`):
```swift
extension Model {
    /// Returns the model's ID or throws a 500 if absent.
    /// Fluent always assigns an ID before persisting, so this should never
    /// throw in practice — but it removes the force-unwrap from the type system.
    func requireID() throws -> IDValue {
        guard let id = self.id else {
            throw Abort(.internalServerError,
                        reason: "\(Self.schema) record has no ID")
        }
        return id
    }
}
```

**Replace force-unwraps across controllers:**

`IndexController.swift`:
```swift
// line 27: ($0.id!, $0)  →  (try $0.requireID(), $0)
// line 32: idx.id!        →  try idx.requireID()
// line 33: idx.id!        →  (already covered by above)
```

`InstrumentController.swift`:
```swift
// line 35: inst.id!.uuidString  →  try inst.requireID().uuidString
// line 59: (in PortfolioActivity) instrument.id!  →  try instrument.requireID()
// line 98: (in PortfolioActivity) existing.id!    →  try existing.requireID()
```

> Note: `PortfolioActivity.swift` line 58, 114 also use `instrument.id!` and
> `existing.id!` — apply the same replacement there.

**Test file:** `Tests/bug-free-memoryTests/ModelExtensionTests.swift` (new)
```swift
// testRequireIDReturnsIDWhenPresent()
// testRequireIDThrows500WhenIDIsNil()
```

---

## Issue #13 — Double Body Decode

**File:** `Sources/bug-free-memory/Controllers/InstrumentController.swift`

The root problem is that `validateContent` both validates and discards the
decoded value, forcing a second decode. The fix decodes once and validates the
decoded value:

```swift
// Before (create, lines 58–59):
if let r = try req.validateContent(CreateInstrumentDTO.self, redirectTo: "/instruments") { return r }
let input = try req.content.decode(CreateInstrumentDTO.self)

// After:
let input = try req.content.decode(CreateInstrumentDTO.self)
if let r = try req.validateContent(input, redirectTo: "/instruments") { return r }
```

This requires `validateContent` to accept a pre-decoded value. If the current
`validateContent` signature only accepts a `Decodable.Type`, add an overload:
```swift
extension Request {
    func validateContent<T: Validatable>(
        _ value: T,
        redirectTo path: String
    ) throws -> Response? {
        do {
            try T.validate(content: self)
            return nil
        } catch let error as ValidationsError {
            return self.flash(error.description, type: "error", to: path)
        }
    }
}
```

Apply the same pattern to `update` (lines 78–79).

**Test file:** `Tests/bug-free-memoryTests/InstrumentControllerTests.swift` (new or extend)
```swift
// testCreateInstrumentDecodesBodyOnce()
//   — mock req.content to count decode calls
//   — assert count == 1 for both valid and invalid payloads
```

---

## Issue #14 — Memory Sessions in Production

**File:** `Sources/bug-free-memory/configure.swift`

**Option A — Redis** (preferred for multi-instance Render deploy):
```swift
// Add package: .package(url: "https://github.com/vapor/redis.git", from: "4.0.0")
// Add target dependency: "Redis", "RedisVapor"

// configure.swift:
import RedisVapor

app.redis.configuration = try .init(
    url: Environment.get("REDIS_URL") ?? "redis://localhost:6379"
)
app.sessions.use(.redis)   // replaces app.sessions.use(.memory)
```

**Option B — Database sessions** (no new infrastructure required):
```swift
// Add package: FluentSessionsDriver (bundled with Fluent)
app.sessions.use(.fluent)
app.migrations.add(SessionRecord.migration)
// Ensure SessionRecord.migration is added BEFORE autoMigrate (or run manually)
```

> Option B requires zero new infra but adds session rows to Postgres and adds
> DB round-trips to every authenticated request. Prefer Option A for
> production; Option B is acceptable for staging.

**Test file:** No automated test is straightforward here. Verify manually:
```
# Deploy two instances; log into one; navigate to the other.
# Flash messages should persist across instances.
```

---

## Issue #15 — `schwab/login` Is Unauthenticated

**File:** `Sources/bug-free-memory/routes.swift`

This change is subsumed by Issue #1 — the login route is re-declared with
`ClerkMiddleware() + ClerkAuthMiddleware()` as part of that fix. No separate
code change is needed beyond what Issue #1 specifies.

**Test:** covered by `testLoginRouteRequiresAuthentication()` in
`SchwabOAuthTests.swift` (see Issue #1).

---

## Issue #16 — Temporal Storage Force-Unwrap

**File:** `Sources/bug-free-memory/configure.swift`

```swift
// Before (lines 17–20):
var temporal: TemporalClient {
    get { storage[TemporalKey.self]! }
    set { storage[TemporalKey.self] = newValue }
}

// After — throwing accessor:
var temporal: TemporalClient {
    get throws {
        guard let client = storage[TemporalKey.self] else {
            throw AppError.missingEnvironmentVariable("TemporalClient (configure() not called)")
        }
        return client
    }
    set { storage[TemporalKey.self] = newValue }
}
```

All call sites that use `req.application.temporal` (or `app.temporal`) must
become `try app.temporal` — search for `\.temporal` across the codebase and
update each. Most are in `routes.swift` and `TemporalController.swift`.

**Test file:** `Tests/bug-free-memoryTests/ConfigureTests.swift`
```swift
// testTemporalAccessBeforeConfigureThrowsDescriptiveError()
//   — create a fresh Application without calling configure()
//   — assert try app.temporal throws (not traps)
```

---

## Issue #17 — `greet/:name` Blocks on Workflow Result

**File:** `Sources/bug-free-memory/routes.swift`

For production: fire-and-forget and return the workflow ID immediately.

```swift
// Before (lines 43–45):
let result: String = try await handle.result()
return result

// After (production-safe):
return "Workflow started: \(handle.workflowId)"
// The client polls or subscribes separately for the result.
```

For demo/testing purposes the current blocking form is acceptable. Add a
comment if keeping it:
```swift
// NOTE: handle.result() blocks this HTTP connection until the workflow
// completes. Acceptable for local demos only — do not use in production paths.
let result: String = try await handle.result()
```

No test required; this is a design note.

---

## Issue #18 — Duplicated Token Refresh Logic

**File:** `Sources/bug-free-memory/routes.swift`

The `/schwab/refresh` POST route (lines 151–186) reimplements token refresh
inline. After Issues #2 and #5 are fixed, this route should delegate entirely
to `SchwabClient`:

```swift
// Before (lines 151–186): ~35 lines of inline refresh logic

// After:
app.grouped(ClerkMiddleware(), ClerkAuthMiddleware()).post("schwab", "refresh") { req async throws -> Response in
    let clerkUserId = req.clerkAuth.userId!
    guard let schwabClient = req.application.schwab else {
        throw AppError.invalidEncryptionKeyConfig
    }
    try await schwabClient.refreshTokenIfNeeded(db: req.db, clerkUserId: clerkUserId)
    app.logger.info("Refreshed Schwab Token for user \(clerkUserId)")
    return req.redirect(to: "/dashboard")
}
```

`refreshTokenIfNeeded` already handles the full refresh cycle, saves to DB,
and updates `self.accessToken` — the route needs only to call it.

**Test file:** `Tests/bug-free-memoryTests/SchwabClientTests.swift`
```swift
// testRefreshRouteCallsRefreshTokenIfNeeded()
//   — POST /schwab/refresh with authenticated session
//   — assert SchwabClient.refreshTokenIfNeeded called (use injectable mock)
//   — assert redirects to /dashboard
```

---

## Issue #19 — `maxConnectionsPerEventLoop` Too Low

**File:** `Sources/bug-free-memory/configure.swift`

```swift
// Before (line 50):
.postgres(url: databaseURL, maxConnectionsPerEventLoop: 2, connectionPoolTimeout: .seconds(30))

// After:
.postgres(url: databaseURL, maxConnectionsPerEventLoop: 4, connectionPoolTimeout: .seconds(30))
```

This gives 16 connections on a 4-core host (up from 8), which is sufficient
for the 6 concurrent pipeline activities plus web traffic headroom.

**Tuning note:** If the Render plan provides only 1 vCPU, NIO runs 1 event loop
and `maxConnectionsPerEventLoop: 4` gives only 4 connections total. In that
case raise to 8:
```swift
maxConnectionsPerEventLoop: Environment.get("SINGLE_CORE") != nil ? 8 : 4
```

Or query the event loop count at startup and set proportionally.

No automated test — verify with a load test against a staging environment
while the daily pipeline is running.

---

## New Files Summary

| File | Purpose |
|---|---|
| `Sources/bug-free-memory/Models/SchwabTokenResponse.swift` | Canonical token response type (Issue #7) |
| `Tests/bug-free-memoryTests/SchwabOAuthTests.swift` | OAuth state CSRF + auth tests (Issues #1, #15) |
| `Tests/bug-free-memoryTests/DashboardTests.swift` | Token not in Leaf context (Issue #3) |
| `Tests/bug-free-memoryTests/InstrumentDTOTests.swift` | parsedInstrumentType throws (Issue #11) |
| `Tests/bug-free-memoryTests/ModelExtensionTests.swift` | requireID() helper (Issue #12) |
| `Tests/bug-free-memoryTests/InstrumentControllerTests.swift` | Single decode (Issue #13) |
| `Tests/bug-free-memoryTests/IndexControllerTests.swift` | Type-safe filter (Issue #9) |
| `Tests/bug-free-memoryTests/ConfigureTests.swift` | CLERK_SECRET_KEY + Temporal guard (Issues #10, #16) |

---

## Modified Files Summary

| File | Issues |
|---|---|
| `Sources/bug-free-memory/routes.swift` | #1, #3, #5, #15, #17, #18 |
| `Sources/bug-free-memory/configure.swift` | #8, #10, #14, #16, #19 |
| `Sources/bug-free-memory/Extensions/SchwabClient+Portfolio.swift` | #2, #4 |
| `Sources/bug-free-memory/Services/SchwabClient.swift` | #5, #7 |
| `Sources/bug-free-memory/Activities/PortfolioActivity.swift` | #2 |
| `Sources/bug-free-memory/Workflows/DailyPipelineWorkflow.swift` | #6 |
| `Sources/bug-free-memory/Models/RunLogInput.swift` | #6 |
| `Sources/bug-free-memory/Controllers/IndexController.swift` | #9, #12 |
| `Sources/bug-free-memory/Controllers/InstrumentController.swift` | #11, #12, #13 |
| `Sources/bug-free-memory/Controllers/SchwabController.swift` | #2 |
| `Sources/bug-free-memory/DTOs/InstrumentDTOs.swift` | #11 |
| `Sources/bug-free-memory/AppError.swift` | #1, #10, #16 |
| `Sources/bug-free-memory/Extensions.swift` | #12 |
