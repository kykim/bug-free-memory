//
//  PortfolioActivityTests.swift
//  bug-free-memory
//
//  TICKET-010: PortfolioActivity integration tests.
//  Uses in-memory SQLite for DB and MockURLProtocol for Schwab HTTP calls.
//

import Testing
import Foundation
import Logging
import Crypto
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - Test DB helper

private func withPortfolioDB(
    _ body: (any Database, SchwabClient) async throws -> Void
) async throws {
    let key = SymmetricKey(size: .bits256)
    let client = SchwabClient(
        accountNumber: "ACC123", clientID: "cid", clientSecret: "csecret",
        encryptionKey: key, accessToken: "")

    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCurrencies())
        app.migrations.add(CreateExchanges())
        app.migrations.add(CreateInstruments())
        app.migrations.add(CreateEquities())
        app.migrations.add(CreateOptionContracts())
        app.migrations.add(CreateOAuthToken())
        try await app.autoMigrate()

        // Seed a non-expired OAuth token so refreshTokenIfNeeded just decrypts
        let encrypted = try TokenEncryption.encrypt("test-access-token", key: key)
        let token = OAuthToken(
            clerkUserId: "user_test", provider: "schwab",
            accessToken: encrypted, refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600))
        try await token.save(on: app.db)
    }) { app in
        try await body(app.db, client)
    }
}

// MARK: - Seed helpers

private func seedEquity(ticker: String, db: any Database) async throws -> Instrument {
    if try await Currency.find("USD", on: db) == nil {
        try await Currency(currencyCode: "USD", name: "US Dollar").save(on: db)
    }

    let exchange: Exchange
    if let existing = try await Exchange.query(on: db).first() {
        exchange = existing
    } else {
        exchange = Exchange(micCode: "XNAS", name: "NASDAQ", countryCode: "US", timezone: "America/New_York")
        try await exchange.save(on: db)
    }

    let instrument = Instrument(
        instrumentType: .equity, ticker: ticker, name: ticker,
        exchangeID: exchange.id!, currencyCode: "USD")
    try await instrument.save(on: db)

    let equity = Equity(instrumentID: instrument.id!)
    try await equity.save(on: db)

    return instrument
}

private func makePositions(_ items: [(ticker: String, type: SchwabAssetType, osi: String?)]) -> Data {
    let json = items.map { item -> String in
        var fields = #"{"symbol":"\#(item.ticker)","assetType":"\#(item.type.rawValue)","quantity":1.0"#
        if let osi = item.osi { fields += #","description":"\#(osi)""# }
        fields += "}"
        return fields
    }.joined(separator: ",")
    return Data("[\(json)]".utf8)
}

private func mockPositions(_ data: Data) {
    MockURLProtocol.handler = { _ in
        (data, HTTPURLResponse(url: URL(string: "https://api.schwabapi.com")!,
                               statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    URLProtocol.registerClass(MockURLProtocol.self)
}

private func unmockPositions() {
    URLProtocol.unregisterClass(MockURLProtocol.self)
    MockURLProtocol.handler = nil
}

private func runActivity(db: any Database, client: SchwabClient, positions: Data) async throws -> FilteredPositionSet {
    mockPositions(positions)
    defer { unmockPositions() }
    let activity = PortfolioActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
    return try await activity.fetchPortfolioPositions(runDate: Date())
}

// MARK: - Tests

@Suite("PortfolioActivity", .serialized)
struct PortfolioActivityTests {

    @Test("Known equity positions are resolved to instrument IDs")
    func equityResolved() async throws {
        try await withPortfolioDB { db, client in
            let aapl = try await seedEquity(ticker: "AAPL", db: db)
            let spy  = try await seedEquity(ticker: "SPY",  db: db)
            let data = makePositions([
                ("AAPL", .equity, nil),
                ("SPY",  .equity, nil),
            ])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.equityInstrumentIDs.contains(aapl.id!))
            #expect(result.equityInstrumentIDs.contains(spy.id!))
            #expect(result.droppedPositions.isEmpty)
        }
    }

    @Test("Equity with no matching instrument is dropped with not_in_equities")
    func equityNotInDB() async throws {
        try await withPortfolioDB { db, client in
            let data = makePositions([("UNKNOWN", .equity, nil)])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.equityInstrumentIDs.isEmpty)
            #expect(result.droppedPositions.count == 1)
            #expect(result.droppedPositions[0].ticker == "UNKNOWN")
            #expect(result.droppedPositions[0].reason == "not_in_equities")
        }
    }

    @Test("Unsupported asset type is dropped with unsupported_asset_type")
    func unsupportedAssetType() async throws {
        try await withPortfolioDB { db, client in
            let data = makePositions([("BOND", .other, nil)])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.equityInstrumentIDs.isEmpty)
            #expect(result.optionInstrumentIDs.isEmpty)
            #expect(result.droppedPositions[0].reason == "unsupported_asset_type")
        }
    }

    @Test("Option with missing OSI symbol is dropped with missing_osi_symbol")
    func optionMissingOSI() async throws {
        try await withPortfolioDB { db, client in
            let data = makePositions([("AAPL", .option, nil)])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.optionInstrumentIDs.isEmpty)
            #expect(result.droppedPositions[0].reason == "missing_osi_symbol")
        }
    }

    @Test("Option with invalid OSI symbol is dropped with osi_parse_error")
    func optionBadOSI() async throws {
        try await withPortfolioDB { db, client in
            let data = makePositions([("AAPL", .option, "INVALID")])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.optionInstrumentIDs.isEmpty)
            #expect(result.droppedPositions[0].reason == "osi_parse_error")
        }
    }

    @Test("Option whose underlying is not in equities is dropped with underlying_not_in_equities")
    func optionUnderlyingNotFound() async throws {
        try await withPortfolioDB { db, client in
            // AAPL not seeded as equity
            let data = makePositions([("AAPL", .option, "AAPL  260320C00175000")])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.optionInstrumentIDs.isEmpty)
            #expect(result.droppedPositions[0].reason == "underlying_not_in_equities")
        }
    }

    @Test("New option contract is registered and counted")
    func newOptionRegistered() async throws {
        try await withPortfolioDB { db, client in
            _ = try await seedEquity(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            let data = makePositions([("AAPL", .option, osiSymbol)])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.optionInstrumentIDs.count == 1)
            #expect(result.newContractsRegistered == 1)
            #expect(result.droppedPositions.isEmpty)
        }
    }

    @Test("Existing option contract is returned without re-registering")
    func existingOptionNotDuplicated() async throws {
        try await withPortfolioDB { db, client in
            let underlying = try await seedEquity(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            let osi = try OSIParser.parse(osiSymbol)

            // Pre-register the contract
            let existingID = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            let data = makePositions([("AAPL", .option, osiSymbol)])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.optionInstrumentIDs == [existingID])
            #expect(result.newContractsRegistered == 0)
        }
    }

    @Test("Mixed positions produce correct counts and drops")
    func mixedPositions() async throws {
        try await withPortfolioDB { db, client in
            _ = try await seedEquity(ticker: "AAPL", db: db)
            _ = try await seedEquity(ticker: "SPY",  db: db)
            let data = makePositions([
                ("AAPL",  .equity, nil),               // resolved
                ("MSFT",  .equity, nil),               // dropped: not_in_equities
                ("BOND",  .other,  nil),               // dropped: unsupported_asset_type
                ("AAPL",  .option, "AAPL  260320C00175000"),  // new contract
                ("SPY",   .option, nil),               // dropped: missing_osi_symbol
            ])
            let result = try await runActivity(db: db, client: client, positions: data)
            #expect(result.equityInstrumentIDs.count == 1)
            #expect(result.optionInstrumentIDs.count == 1)
            #expect(result.newContractsRegistered == 1)
            #expect(result.droppedPositions.count == 3)
            let reasons = Set(result.droppedPositions.map(\.reason))
            #expect(reasons == ["not_in_equities", "unsupported_asset_type", "missing_osi_symbol"])
        }
    }
}
