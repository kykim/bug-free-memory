import Vapor
import ClerkVapor
import TiingoKit

struct SchwabTokenResponse: Content {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

func routes(_ app: Application) throws {
    app.get { req async in
        return req.redirect(to: "/dashboard")
    }

    app.get("hello") { req async throws -> View in
        return try await req.view.render("hello", ["name": "Leaf"])
    }
    
    app.get("greet", ":name") { req async throws -> String in
        let name = try req.parameters.require("name")
        req.logger.info("Triggering workflow for \(name)")
        req.logger.info("About to call startWorkflow")
        let handle = try await req.application.temporal.startWorkflow(
            type: GreetingWorkflow.self,
            options: .init(
                id: "greet-\(name)-\(UUID())",
                taskQueue: "greeting-queue"
            ),
            input: name
        )
        req.logger.info("startWorkflow returned, calling result()")
        let result: String = try await handle.result()
        req.logger.info("result() returned")
        return result
    }

    app.grouped(ClerkMiddleware()).get("dashboard") { req async throws -> View in
        struct Context: Encodable {
            var appName: String
            var pageTitle: String
            var schwabConnected: Bool
            var schwabAccessToken: String?
            var schwabRefreshToken: String?
            var schwabTokenExpiresAt: String?
        }
        var schwabToken: OAuthToken? = nil
        if let userId = req.clerkAuth.userId {
            schwabToken = try await OAuthToken.query(on: req.db)
                .filter(\OAuthToken.$clerkUserId, .equal, userId)
                .filter(\OAuthToken.$provider, .equal, "schwab")
                .first()
        }
        return try await req.clerkView("dashboard", context: Context(
            appName: "bug-free-memory",
            pageTitle: "Dashboard",
            schwabConnected: schwabToken != nil,
            schwabAccessToken: schwabToken?.accessToken,
            schwabRefreshToken: schwabToken?.refreshToken,
            schwabTokenExpiresAt: schwabToken.map { ISO8601DateFormatter().string(from: $0.expiresAt) }
        ))
    }
    
    // Schwab OAuth - user must be logged in via Clerk first
    app.get("schwab", "login") { req -> Response in
        let clientID = Environment.get("SCHWAB_CLIENT_ID") ?? ""
        let redirectURI = Environment.get("SCHWAB_REDIRECT_URI") ?? "http://localhost:8080/schwab/callback"
        
        var components = URLComponents(string: "https://api.schwabapi.com/v1/oauth/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
        ]
        app.logger.info("\(components.url!)")
        return req.redirect(to: components.url!.absoluteString, redirectType: .temporary)
    }

    app.grouped(ClerkMiddleware(), ClerkAuthMiddleware()).get("schwab", "callback") { req async throws -> Response in
        guard let code = req.query[String.self, at: "code"] else {
            throw Abort(.badRequest, reason: "Missing authorization code")
        }

        app.logger.info("Got Schwab Callback")

        let clerkUserId = req.clerkAuth.userId!
        let clientID = Environment.get("SCHWAB_CLIENT_ID") ?? ""
        let clientSecret = Environment.get("SCHWAB_CLIENT_SECRET") ?? ""
        let redirectURI = Environment.get("SCHWAB_REDIRECT_URI") ?? "http://localhost:8080/schwab/callback"

        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Basic \(credentials)")
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")

        let tokenResponse = try await req.client.post("https://api.schwabapi.com/v1/oauth/token", headers: headers) { r in
            r.body = .init(string: "grant_type=authorization_code&code=\(code)&redirect_uri=\(redirectURI)")
        }

        let token = try tokenResponse.content.decode(SchwabTokenResponse.self)
        let tokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))

        if let existing = try await OAuthToken.query(on: req.db)
            .filter(\OAuthToken.$clerkUserId, .equal, clerkUserId)
            .filter(\OAuthToken.$provider, .equal, "schwab")
            .first() {
            existing.accessToken = token.accessToken
            existing.refreshToken = token.refreshToken
            existing.expiresAt = tokenExpiresAt
            try await existing.save(on: req.db)
        } else {
            let oauthToken = OAuthToken(
                clerkUserId: clerkUserId,
                provider: "schwab",
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                expiresAt: tokenExpiresAt
            )
            try await oauthToken.save(on: req.db)
        }

        app.logger.info("Saved Schwab Token for user \(clerkUserId)")
        return req.redirect(to: "/dashboard")
    }

    app.grouped(ClerkMiddleware(), ClerkAuthMiddleware()).post("schwab", "refresh") { req async throws -> Response in
        let clerkUserId = req.clerkAuth.userId!
        guard let existing = try await OAuthToken.query(on: req.db)
            .filter(\OAuthToken.$clerkUserId, .equal, clerkUserId)
            .filter(\OAuthToken.$provider, .equal, "schwab")
            .first() else {
            throw Abort(.badRequest, reason: "No Schwab token found")
        }
        guard let refreshToken = existing.refreshToken else {
            throw Abort(.badRequest, reason: "No refresh token stored")
        }

        let clientID = Environment.get("SCHWAB_CLIENT_ID") ?? ""
        let clientSecret = Environment.get("SCHWAB_CLIENT_SECRET") ?? ""
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()

        var headers = HTTPHeaders()
        headers.add(name: .authorization, value: "Basic \(credentials)")
        headers.add(name: .contentType, value: "application/x-www-form-urlencoded")

        let tokenResponse = try await req.client.post("https://api.schwabapi.com/v1/oauth/token", headers: headers) { r in
            r.body = .init(string: "grant_type=refresh_token&refresh_token=\(refreshToken)")
        }

        let token = try tokenResponse.content.decode(SchwabTokenResponse.self)
        let tokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        existing.accessToken = token.accessToken
        existing.refreshToken = token.refreshToken ?? existing.refreshToken
        existing.expiresAt = tokenExpiresAt
        try await existing.save(on: req.db)

        app.logger.info("Refreshed Schwab Token for user \(clerkUserId)")
        return req.redirect(to: "/dashboard")
    }

    // Public route — clerkAuth is populated but not required
    app.grouped(ClerkMiddleware()).get("public") { req -> String in
        if req.clerkAuth.isAuthenticated {
            return "Hello, \(req.clerkAuth.userId!)"
        }
        return "Hello, stranger"
    }

    // Protected routes — returns 401 if no valid session
    let auth = app.grouped(ClerkMiddleware(), ClerkAuthMiddleware())

    auth.get("me") { req async throws -> ClerkUser in
        let userId = req.clerkAuth.userId!
        return try await req.clerkClient.users.getUser(userId: userId)
    }

    // Organisation-scoped route
    let adminOnly = auth.grouped(ClerkOrgMiddleware(role: "org:admin"))
    adminOnly.delete("users", ":userId") { req async throws -> HTTPStatus in
        let targetId = try req.parameters.require("userId")
        _ = try await req.clerkClient.users.deleteUser(userId: targetId)
        return .noContent
    }
}
