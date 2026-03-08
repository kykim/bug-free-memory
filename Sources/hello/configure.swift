import Vapor
import Fluent
import FluentPostgresDriver
import Leaf
import ClerkVapor
import ClerkLeaf

// configures your application
public func configure(_ app: Application) async throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
    let databaseURL = Environment.get("DATABASE_URL") ?? "postgres://vapor:password@localhost:5432/vapor"
    try app.databases.use(.postgres(url: databaseURL), as: .psql)

    // Register migrations
    try await app.autoMigrate()

    app.useClerk(ClerkConfiguration(
            secretKey: Environment.get("CLERK_SECRET_KEY")!,
            publishableKey: Environment.get("CLERK_PUBLISHABLE_KEY"),
            // Optional: PEM key for networkless JWT verification
            // jwtKey: Environment.get("CLERK_JWT_KEY"),
            authorizedParties: ["https://bug-free-memory-4mtc.onrender.com", "http://localhost:8080"]
        ))
    app.useClerkLeaf()               // registers tags + enables Leaf renderer
    app.addClerkLeafSources()        // registers both your app's Views + the bundled Clerk templates
    app.registerClerkRoutes()        // optional: adds /sign-in, /sign-up, /profile routes

    // register routes
    try routes(app)
}


