import Vapor
import ClerkVapor

func routes(_ app: Application) throws {
    app.get { req async in
        return req.redirect(to: "/dashboard")
    }

    app.get("hello") { req async throws -> View in
        return try await req.view.render("hello", ["name": "Leaf"])    }
    
    app.get("dashboard") { req async throws -> View in
        try await req.clerkView("dashboard", context: [
            "appName": "bug-free-memory",
            "pageTitle": "Dashboard",
        ])
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
