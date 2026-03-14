# Code Review

> Reviewed as staff-level Swift / Vapor / Temporal engineer — 2026-03-13

---

## Critical — Security

### 1. Missing OAuth `state` parameter (CSRF) — `routes.swift:90-95`

The Schwab OAuth login flow has no `state` parameter. Without one, an attacker can craft a callback URL with their own `code` and trick an authenticated user into linking the attacker's Schwab account.

```swift
// Missing:
let state = UUID().uuidString
req.session.data["oauthState"] = state
components.queryItems = [..., .init(name: "state", value: state)]

// And in callback: verify req.query["state"] == session["oauthState"]
```

### 2. `refreshTokenIfNeeded` missing `clerkUserId` filter — `SchwabClient+Portfolio.swift:57-59`

```swift
// BUG: grabs the FIRST Schwab token in the DB, regardless of owner
guard let tokenRow = try await OAuthToken.query(on: db)
    .filter(\.$provider == "schwab")
    .first() else {
```

Every other call site (e.g., `routes.swift:153-156`, `SchwabController.swift:17-20`) correctly filters by `clerkUserId`. The `PortfolioActivity` doesn't receive the userId at all — this is a design gap that needs the userId threaded through `DailyPipelineInput` → activity input, or a dedicated "single-user" sentinel enforced at a higher level.

### 3. Decrypted access token in Leaf context — `routes.swift:71,81`

```swift
schwabAccessToken = try TokenEncryption.decrypt(token.accessToken, key: key)
// ...
schwabAccessToken: schwabAccessToken   // sent to template
```

The decrypted bearer token is passed to the template context. Even if the template doesn't render it in HTML, it appears in any context serialization, debug logs, or error pages. Don't pass decrypted tokens to the view layer.

---

## High — Correctness / Reliability

### 4. Double token refresh race condition — `SchwabController.swift:35-63`

Two concurrent `GET /schwab/portfolio` requests will both see the token as expired, both call Schwab's refresh endpoint, and both save a new token. Schwab refresh tokens are **single-use** — the second refresh will fail or invalidate the session. There's no advisory lock, `SELECT FOR UPDATE`, or actor-based coordination here.

The correct fix is to push the refresh into the `SchwabClient` actor (or use `SchwabClient.refreshTokenIfNeeded(db:)` which already exists) and serialize it, or use a DB-level lock.

### 5. Refresh token not URL-percent-encoded — `routes.swift:119,174` and `SchwabController.swift:51`

```swift
r.body = .init(string: "grant_type=refresh_token&refresh_token=\(refreshToken)")
```

OAuth tokens are typically base64url strings containing `+`, `=`, and `/`. These **must** be percent-encoded in `application/x-www-form-urlencoded` bodies. An unencoded `=` splits a value, a `+` becomes a space. This is a silent, intermittent bug that appears only for certain token values.

Fix: use `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)` or compose via `URLComponents`.

### 6. `Date()` inside a Temporal Workflow — `DailyPipelineWorkflow.swift:28,54,167`

```swift
let startedAt = Date()   // line 28
completedAt: Date()      // line 54, line 167
```

Workflows must be deterministic. On replay, `Date()` produces different values than the original execution, causing history mismatch. Use `Workflow.now` (if the Swift SDK exposes it) or pass timestamps as activity results / workflow inputs. At minimum, capture a single timestamp once via a side effect.

### 7. Duplicate `SchwabTokenResponse` with divergent shapes

There are three separate definitions:

- `routes.swift:5-18` — has `idToken`, `tokenType`, uses `CodingKeys`
- `SchwabController.swift:53-57` — local, snake_case fields, no `idToken`/`tokenType`
- `SchwabClient.swift:28-32` (private) — snake_case, no `idToken`/`tokenType`

The local struct in `SchwabController.portfolio()` **shadows** the module-level one. The missing `tokenType` field means decoding will fail if Schwab returns a non-optional `token_type` (it always does). Consolidate into one canonical `SchwabTokenResponse` in a shared file.

### 8. `autoMigrate()` on every startup — `configure.swift:62`

```swift
try await app.autoMigrate()
```

Running migrations unconditionally at server startup is dangerous in production. A slow or destructive migration blocks startup and can cascade across instances. Migrations should be a discrete step (`vapor run migrate`) before deployment, not a side effect of starting the server.

---

## Medium — Code Quality / Reliability

### 9. `unsafeRaw` SQL filter — `IndexController.swift:17`

```swift
.filter(.sql(unsafeRaw: "\"instrument_type\" = 'index'::instrument_type"))
```

Fluent's `@Enum` property wrapper supports type-safe filtering. This should be:

```swift
.filter(\.$instrumentType == .index)
```

If a Postgres enum casting issue forced this workaround, it should be documented with a ticket, not left as silent unsafe SQL.

### 10. Force-unwrapping `CLERK_SECRET_KEY` — `configure.swift:65`

```swift
secretKey: Environment.get("CLERK_SECRET_KEY")!,
```

This crashes the process at startup with a cryptic message if the env var is absent. Use `guard let` and throw a descriptive error.

### 11. Force-unwrapping `parsedInstrumentType` — `InstrumentDTOs.swift:34`

```swift
var parsedInstrumentType: InstrumentType { InstrumentType(rawValue: instrument_type)! }
```

Validation in `validations(_:)` guards this, but the property itself will crash if accessed before validation. The validation and parsing should be coupled (return `InstrumentType` from a throwing function), not separated by a force-unwrap assumption.

### 12. Pervasive `model.id!` force-unwraps — `IndexController.swift:21,32,33`, `InstrumentController.swift:35,59,98`

Models retrieved from Fluent always have IDs, so these won't crash in practice — but each `!` is a "trust me" that bypasses the type system. Use `guard let id = model.id else { throw Abort(.internalServerError) }` or a shared helper extension.

### 13. Double decode of request body — `InstrumentController.swift:58-59,78-79`

```swift
if let r = try req.validateContent(CreateInstrumentDTO.self, redirectTo: "/instruments") { return r }
let input = try req.content.decode(CreateInstrumentDTO.self)
```

`validateContent` internally calls `T.validate(content:)` which decodes the body. Then the body is decoded again. Vapor caches the decoded body so this is functionally correct, but it should decode once and reuse.

### 14. Memory sessions in production — `configure.swift:33`

```swift
app.sessions.use(.memory)
```

Flash messages (the main user-facing feedback mechanism) rely on sessions. Memory sessions are per-instance and per-restart. With multiple Render instances or a single restart, flash messages are lost silently. Use Redis or database-backed sessions.

### 15. `schwab/login` is unauthenticated — `routes.swift:86`

The OAuth initiation route has no `ClerkMiddleware`. Anyone can hit this URL and trigger an OAuth flow. While low severity given no `state` param is even validated, requiring auth here is defense-in-depth and avoids wasted OAuth round trips.

### 16. `Temporal` storage force-unwrap — `configure.swift:17-19`

```swift
var temporal: TemporalClient {
    get { storage[TemporalKey.self]! }
```

If a future code path accesses `app.temporal` before `configure()` completes (e.g., a test, a command that doesn't call configure), this crashes. Use `get throws` or expose it as optional.

---

## Low — Design Notes

### 17. `greet/:name` blocks on workflow result — `routes.swift:43`

`handle.result()` holds the HTTP connection open until the Temporal workflow finishes. Fine for a demo; not appropriate for anything user-facing.

### 18. `SchwabController` re-implements token refresh instead of using `SchwabClient`

`SchwabClient.refreshTokenIfNeeded(db:)` already exists. `SchwabController.portfolio()` duplicates the refresh logic inline. This is the third copy of that refresh block (`routes.swift` `/schwab/refresh` is the second). Consolidate.

### 19. `maxConnectionsPerEventLoop: 2` — `configure.swift:42`

With 4+ event loops (typical multi-core deploy), that's ≤8 total Postgres connections. The daily pipeline runs multiple concurrent DB operations. Under load, the 30-second `connectionPoolTimeout` may trigger. Tune to at least 4-5 per event loop, or benchmark under realistic load.

---

## Summary

| # | File | Severity | Issue |
|---|------|----------|-------|
| 1 | `routes.swift` | **Critical** | No OAuth `state` — CSRF |
| 2 | `SchwabClient+Portfolio.swift` | **Critical** | Missing `clerkUserId` filter |
| 3 | `routes.swift` | **Critical** | Decrypted token in view context |
| 4 | `SchwabController.swift` | High | Concurrent refresh race condition |
| 5 | `routes.swift`, `SchwabController.swift` | High | Refresh token not URL-encoded |
| 6 | `DailyPipelineWorkflow.swift` | High | `Date()` violates Temporal determinism |
| 7 | Multiple | High | Three divergent `SchwabTokenResponse` types |
| 8 | `configure.swift` | High | `autoMigrate()` on every server start |
| 9 | `IndexController.swift` | Medium | `unsafeRaw` SQL filter |
| 10 | `configure.swift` | Medium | Force-unwrap on `CLERK_SECRET_KEY` |
| 11 | `InstrumentDTOs.swift` | Medium | Force-unwrap `parsedInstrumentType` |
| 12 | Controllers | Medium | Pervasive `model.id!` |
| 13 | `InstrumentController.swift` | Medium | Double body decode |
| 14 | `configure.swift` | Medium | Memory sessions in production |
| 15 | `routes.swift` | Medium | Unauthenticated OAuth initiation |
| 16 | `configure.swift` | Medium | Temporal storage force-unwrap |
| 17 | `routes.swift` | Low | `greet` route blocks on workflow result |
| 18 | `SchwabController.swift` | Low | Duplicated token refresh logic |
| 19 | `configure.swift` | Low | `maxConnectionsPerEventLoop` too low |

The top priorities to fix before any production use are **#1** (CSRF), **#2** (wrong-user tokens), **#5** (broken token encoding), and **#6** (Temporal determinism).
