import Vapor
import ClerkVapor
import TiingoKit

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
    
    app.get("prices", ":ticker") { req async throws -> [Tiingo.EODPrice] in
        try await req.tiingo.eod(ticker: req.parameters.get("ticker")!)
    }

    
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
