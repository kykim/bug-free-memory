import NIOSSL
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
//    try app.databases.use(.postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql)
    
    var tlsConfig = TLSConfiguration.makeClientConfiguration()
    tlsConfig.certificateVerification = .none  // disables cert verification

    var postgresConfig = try SQLPostgresConfiguration(url: databaseURL)
    postgresConfig.coreConfiguration.tls = .require(try NIOSSLContext(configuration: tlsConfig))

    app.databases.use(.postgres(configuration: postgresConfig, maxConnectionsPerEventLoop: 1), as: .psql)

    // Register migrations
    app.migrations.add(CreateCurrencies())       // no deps
    app.migrations.add(CreateExchanges())        // no deps
    app.migrations.add(CreateInstruments())      // depends on currencies, exchanges
    app.migrations.add(CreateEquities())         // depends on instruments
    app.migrations.add(CreateIndexes())          // depends on instruments
    app.migrations.add(CreateOptionContracts())  // depends on instruments
    app.migrations.add(CreateEODPrices())        // depends on instruments
    app.migrations.add(CreateOptionEODPrices())  // depends on instruments
    app.migrations.add(CreateCorporateActions()) // depends on instruments

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
    try app.register(collection: CurrencyController())
    try routes(app)
}


