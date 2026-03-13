import NIOSSL
import Vapor
import Fluent
import FluentPostgresDriver
import Leaf
import Temporal
import ClerkVapor
import ClerkLeaf
import TiingoKit
import Crypto

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
    if let keyBase64 = Environment.get("TOKEN_ENCRYPTION_KEY") {
        guard let keyData = Data(base64Encoded: keyBase64), keyData.count == 32 else {
            throw AppError.invalidEncryptionKeyConfig
        }
        app.tokenEncryptionKey = SymmetricKey(data: keyData)
    }
    // Workers don't set TOKEN_ENCRYPTION_KEY and never call OAuth routes, so absence is fine.

    app.sessions.use(.memory)

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(app.sessions.middleware)

    app.tiingo = TiingoClient(apiKey: Environment.get("TIINGO_API_KEY") ?? "")

    let databaseURL = Environment.get("DATABASE_URL") ?? "postgres://vapor:password@localhost:5432/vapor"
    try app.databases.use(
        .postgres(url: databaseURL, maxConnectionsPerEventLoop: 2, connectionPoolTimeout: .seconds(30)),
        as: .psql
    )

    // Register migrations
    app.migrations.add(CreateMarketHolidays())   // no deps
    app.migrations.add(CreateCurrencies())       // no deps
    app.migrations.add(CreateExchanges())        // no deps
    app.migrations.add(CreateInstruments())      // depends on currencies, exchanges
    app.migrations.add(CreateEquities())         // depends on instruments
    app.migrations.add(CreateIndexes())          // depends on instruments
    app.migrations.add(CreateOptionContracts())  // depends on instruments
    app.migrations.add(CreateEODPrices())        // depends on instruments
    app.migrations.add(CreateOptionEODPrices())  // depends on instruments
    app.migrations.add(CreateCorporateActions()) // depends on instruments
    app.migrations.add(CreateTheoreticalOptionEODPrice())
    app.migrations.add(CreateFREDYield())
    app.migrations.add(CreateOAuthToken())
    app.migrations.add(CreateJobRuns())

    try await app.autoMigrate()

    app.useClerk(ClerkConfiguration(
        secretKey: Environment.get("CLERK_SECRET_KEY")!,
        publishableKey: Environment.get("CLERK_PUBLISHABLE_KEY"),
        // Optional: PEM key for networkless JWT verification
        // jwtKey: Environment.get("CLERK_JWT_KEY"),
        authorizedParties: [
            "https://bug-free-memory-4mtc.onrender.com",
            "https://sandee-locular-hereditarily.ngrok-free.dev",
            "http://localhost:8080"
        ]
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
    app.lifecycle.use(TemporalClientService(app: app))
    app.asyncCommands.use(WorkerCommand(), as: "worker")
    app.asyncCommands.use(RegisterScheduleCommand(), as: "register-schedule")

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
    try app.register(collection: FREDYieldController())
    try app.register(collection: MarketHolidayController())
    try routes(app)
}


