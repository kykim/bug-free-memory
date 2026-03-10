import NIOSSL
import Vapor
import Fluent
import FluentPostgresDriver
import Leaf
import Temporal
import ClerkVapor
import ClerkLeaf
import TiingoKit

// Extend Application to store the Temporal client
extension Application {
    struct TemporalKey: StorageKey {
        typealias Value = TemporalClient
    }
    var temporal: TemporalClient {
        get { storage[TemporalKey.self]! }
        set { storage[TemporalKey.self] = newValue }
    }
}

// configures your application
public func configure(_ app: Application) async throws {
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    
    app.tiingo = TiingoClient(apiKey: Environment.get("TIINGO_API_KEY") ?? "")

    let databaseURL = Environment.get("DATABASE_URL") ?? "postgres://vapor:password@localhost:5432/vapor"
    try app.databases.use(.postgres(url: databaseURL, maxConnectionsPerEventLoop: 1), as: .psql)

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

    // Register Temporal client
    app.temporal = try TemporalClient(
        target: .dns(host: "temporal", port: 7233),
        transportSecurity: .plaintext,
        configuration: .init(
            instrumentation: .init(serverHostname: "temporal")
        ),
        logger: app.logger
    )
    app.lifecycle.use(TemporalWorkerService(app: app))

    // register routes
    try app.register(collection: CurrencyController())
    try app.register(collection: ExchangeController())
    try app.register(collection: InstrumentController())
    try app.register(collection: EquityController())
    try app.register(collection: IndexController())
    try app.register(collection: OptionContractController())
    try app.register(collection: EODPriceController())
    try app.register(collection: OptionEODPriceController())
    try app.register(collection: CorporateActionController())
    try routes(app)
}


