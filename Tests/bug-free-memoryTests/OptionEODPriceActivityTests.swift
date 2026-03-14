//
//  OptionEODPriceActivityTests.swift
//  bug-free-memory
//
//  TICKET-012: OptionEODPriceActivity integration tests.
//  Uses in-memory SQLite + MockURLProtocol for Schwab calls.
//
//  NOTE: CreateOptionEODPrices uses a PostgreSQL-specific GENERATED ALWAYS AS
//  column for `mid`. The test migration below omits that column so the suite
//  runs on SQLite.
//

import Testing
import Foundation
import Logging
import Crypto
import Fluent
import FluentSQL
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - Isolated mock protocol for OptionEODPriceActivity tests

final class MockOptionEODURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockOptionEODURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - SQLite-compatible option_eod_prices migration (no generated column)

struct TestCreateOptionEODPrices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("option_eod_prices")
            .field("id", .uuid, .required, .identifier(auto: false))
            .field("instrument_id", .uuid, .required,
                   .references("instruments", "id", onDelete: .cascade))
            .field("price_date", .date, .required)
            .field("bid", .double)
            .field("ask", .double)
            .field("last", .double)
            .field("settlement_price", .double)
            .field("volume", .int64)
            .field("open_interest", .int64)
            .field("implied_volatility", .double)
            .field("delta", .double)
            .field("gamma", .double)
            .field("theta", .double)
            .field("vega", .double)
            .field("rho", .double)
            .field("underlying_price", .double)
            .field("risk_free_rate", .double)
            .field("dividend_yield", .double)
            .field("source", .string)
            .field("created_at", .datetime)
            .unique(on: "instrument_id", "price_date")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("option_eod_prices").delete()
    }
}

// MARK: - DB + client helper

private func withOptionEODDB(
    _ body: (any Database, SchwabClient) async throws -> Void
) async throws {
    let key = SymmetricKey(size: .bits256)
    let mockConfig = URLSessionConfiguration.ephemeral
    mockConfig.protocolClasses = [MockOptionEODURLProtocol.self]
    let mockSession = URLSession(configuration: mockConfig)
    let client = SchwabClient(
        accountNumber: "ACC123", clientID: "cid", clientSecret: "csecret",
        encryptionKey: key, accessToken: "", session: mockSession)

    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCurrencies())
        app.migrations.add(CreateExchanges())
        app.migrations.add(CreateInstruments())
        app.migrations.add(CreateEquities())
        app.migrations.add(CreateOptionContracts())
        app.migrations.add(CreateFREDYield())
        app.migrations.add(CreateOAuthToken())
        app.migrations.add(TestCreateOptionEODPrices())
        try await app.autoMigrate()

        // Non-expired OAuth token so refreshTokenIfNeeded only decrypts
        let encrypted = try TokenEncryption.encrypt("access-token", key: key)
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

private func seedUnderlying(ticker: String, db: any Database) async throws -> Instrument {
    if try await Currency.find("USD", on: db) == nil {
        try await Currency(currencyCode: "USD", name: "US Dollar").save(on: db)
    }
    let exchange: Exchange
    if let e = try await Exchange.query(on: db).first() { exchange = e } else {
        exchange = Exchange(micCode: "XNAS", name: "NASDAQ", countryCode: "US", timezone: "America/New_York")
        try await exchange.save(on: db)
    }
    let instrument = Instrument(instrumentType: .equity, ticker: ticker, name: ticker,
                                exchangeID: exchange.id!, currencyCode: "USD")
    try await instrument.save(on: db)
    try await Equity(instrumentID: instrument.id!).save(on: db)
    return instrument
}

private func seedContract(
    osiSymbol: String,
    underlying: Instrument,
    expirationDate: Date,
    db: any Database
) async throws -> OptionContract {
    let instrument = Instrument(
        instrumentType: .equityOption, ticker: osiSymbol, name: osiSymbol,
        exchangeID: underlying.$exchange.id, currencyCode: "USD")
    try await instrument.save(on: db)

    let contract = OptionContract(
        instrumentID: instrument.id!,
        underlyingID: underlying.id!,
        optionType: .call,
        exerciseStyle: .american,
        strikePrice: 175.0,
        expirationDate: expirationDate,
        contractMultiplier: 100,
        settlementType: "physical",
        osiSymbol: osiSymbol)
    try await contract.create(on: db)
    return contract
}

private func quoteJSON(_ osiSymbol: String, bid: Double = 1.10, ask: Double = 1.20) -> Data {
    Data("""
    {"\(osiSymbol)": {"quote": {"bid": \(bid), "ask": \(ask), "last": 1.15, "volatility": 0.30,
     "underlyingPrice": 175.0, "delta": 0.45, "gamma": 0.02, "theta": -0.05,
     "vega": 0.10, "rho": 0.01, "volume": 500, "openInterest": 1200}}}
    """.utf8)
}

private func emptyQuoteJSON() -> Data { Data("{}".utf8) }

private func mockSchwab(_ body: Data, statusCode: Int = 200) {
    MockOptionEODURLProtocol.handler = { _ in
        (body, HTTPURLResponse(url: URL(string: "https://api.schwabapi.com")!,
                               statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
}

private func unmockSchwab() {
    MockOptionEODURLProtocol.handler = nil
}

private func futureDate(daysFromNow: Int = 30) -> Date {
    Date().addingTimeInterval(Double(daysFromNow) * 86400)
}

private func pastDate(daysAgo: Int = 1) -> Date {
    Date().addingTimeInterval(-Double(daysAgo) * 86400)
}

// MARK: - Tests

@Suite("OptionEODPriceActivity", .serialized)
struct OptionEODPriceActivityTests {

    @Test("Non-expired contract with valid quote is upserted")
    func happyPath() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            _ = try await seedContract(osiSymbol: osiSymbol, underlying: underlying,
                                       expirationDate: futureDate(), db: db)

            mockSchwab(quoteJSON(osiSymbol))
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            let result = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())

            #expect(result.rowsUpserted == 1)
            #expect(result.skippedContracts.isEmpty)
            #expect(result.contractsProcessed == 1)
        }
    }

    @Test("Expired contracts are not processed")
    func expiredContractSkipped() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            _ = try await seedContract(osiSymbol: "AAPL  250101C00175000", underlying: underlying,
                                       expirationDate: pastDate(), db: db)

            mockSchwab(emptyQuoteJSON())
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            let result = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())

            #expect(result.contractsProcessed == 0)
            #expect(result.rowsUpserted == 0)
        }
    }

    @Test("No quote from Schwab → skipped with no_quote")
    func noQuoteSkipped() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            _ = try await seedContract(osiSymbol: osiSymbol, underlying: underlying,
                                       expirationDate: futureDate(), db: db)

            mockSchwab(emptyQuoteJSON())
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            let result = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())

            #expect(result.rowsUpserted == 0)
            #expect(result.skippedContracts.count == 1)
            #expect(result.skippedContracts[0].reason == "no_quote")
            #expect(result.skippedContracts[0].osiSymbol == osiSymbol)
        }
    }

    @Test("Auth failure from Schwab is rethrown")
    func authFailureRethrown() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            _ = try await seedContract(osiSymbol: "AAPL  260320C00175000", underlying: underlying,
                                       expirationDate: futureDate(), db: db)

            mockSchwab(Data("unauthorized".utf8), statusCode: 401)
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            do {
                _ = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())
                Issue.record("Expected authFailure to be thrown")
            } catch SchwabError.authFailure { /* expected */ }
        }
    }

    @Test("Upsert is idempotent — running twice leaves one row with updated values")
    func upsertIdempotent() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            _ = try await seedContract(osiSymbol: osiSymbol, underlying: underlying,
                                       expirationDate: futureDate(), db: db)

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))

            mockSchwab(quoteJSON(osiSymbol, bid: 1.10, ask: 1.20))
            _ = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())
            unmockSchwab()

            mockSchwab(quoteJSON(osiSymbol, bid: 1.50, ask: 1.60))
            _ = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())
            unmockSchwab()

            let rows = try await OptionEODPrice.query(on: db).all()
            #expect(rows.count == 1)
            #expect(rows[0].bid == 1.50)
            #expect(rows[0].ask == 1.60)
        }
    }

    @Test("Multiple contracts all upserted")
    func multipleContracts() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            let symbols = ["AAPL  260320C00175000", "AAPL  260320P00150000", "AAPL  260620C00180000"]
            for sym in symbols {
                _ = try await seedContract(osiSymbol: sym, underlying: underlying,
                                           expirationDate: futureDate(), db: db)
            }

            nonisolated(unsafe) var callCount = 0
            MockOptionEODURLProtocol.handler = { req in
                callCount += 1
                let sym = symbols[(callCount - 1) % symbols.count]
                return (quoteJSON(sym),
                        HTTPURLResponse(url: URL(string: "https://api.schwabapi.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            let result = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())

            #expect(result.contractsProcessed == 3)
            #expect(result.rowsUpserted == 3)
            #expect(result.skippedContracts.isEmpty)
        }
    }

    @Test("Risk-free rate defaults to 0.05 when no FRED yields seeded")
    func riskFreeRateDefaultsTo5Percent() async throws {
        try await withOptionEODDB { db, client in
            let underlying = try await seedUnderlying(ticker: "AAPL", db: db)
            let osiSymbol = "AAPL  260320C00175000"
            _ = try await seedContract(osiSymbol: osiSymbol, underlying: underlying,
                                       expirationDate: futureDate(), db: db)

            mockSchwab(quoteJSON(osiSymbol))
            defer { unmockSchwab() }

            let activity = OptionEODPriceActivities(db: db, schwabClient: client, logger: Logger(label: "test"))
            _ = try await activity.fetchAndUpsertOptionEODPrices(runDate: Date())

            let row = try await OptionEODPrice.query(on: db).first()!
            #expect(abs((row.riskFreeRate ?? 0) - 0.05) < 0.0001)
        }
    }
}
