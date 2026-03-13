//
//  EODPriceActivityTests.swift
//  bug-free-memory
//
//  TICKET-011: EODPriceActivity integration tests.
//  Uses in-memory SQLite for DB and a custom URLSession for Tiingo HTTP calls.
//

import Testing
import Foundation
import Logging
import Fluent
import FluentSQLiteDriver
import TiingoKit
import VaporTesting
@testable import bug_free_memory

// MARK: - Isolated mock protocol for EODPriceActivity / Tiingo tests

final class MockTiingoURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockTiingoURLProtocol.handler else {
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

// MARK: - DB helper

private func withEODDB(_ body: (any Database, TiingoClient) async throws -> Void) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockTiingoURLProtocol.self]
    let session = URLSession(configuration: config)
    let tiingo = TiingoClient(apiKey: "test-key", session: session)

    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCurrencies())
        app.migrations.add(CreateExchanges())
        app.migrations.add(CreateInstruments())
        app.migrations.add(CreateEquities())
        app.migrations.add(CreateIndexes())
        app.migrations.add(CreateEODPrices())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db, tiingo)
    }
}

// MARK: - Seed helpers

private func seedEquityInstrument(ticker: String, db: any Database) async throws -> Instrument {
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
    let instrument = Instrument(instrumentType: .equity, ticker: ticker, name: ticker,
                                exchangeID: exchange.id!, currencyCode: "USD", isActive: true)
    try await instrument.save(on: db)
    try await Equity(instrumentID: instrument.id!).save(on: db)
    return instrument
}

private func seedInactiveEquity(ticker: String, db: any Database) async throws -> Instrument {
    let instrument = try await seedEquityInstrument(ticker: ticker, db: db)
    instrument.isActive = false
    try await instrument.save(on: db)
    return instrument
}

// MARK: - Tiingo JSON helpers

private func tiingoPriceJSON(date: String = "2026-03-13T00:00:00+00:00",
                              close: Double = 175.0) -> Data {
    Data("""
    [{
        "date": "\(date)",
        "open": 173.0, "high": 176.0, "low": 172.0, "close": \(close),
        "volume": 50000000,
        "adjClose": \(close), "adjOpen": 173.0, "adjHigh": 176.0, "adjLow": 172.0,
        "adjVolume": 50000000, "divCash": 0.0, "splitFactor": 1.0
    }]
    """.utf8)
}

private func mockTiingo(statusCode: Int = 200, body: Data,
                        forTicker ticker: String? = nil) {
    MockTiingoURLProtocol.handler = { _ in
        (body, HTTPURLResponse(url: URL(string: "https://api.tiingo.com")!,
                               statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
}

// MARK: - Run helper

private func runActivity(db: any Database, tiingo: TiingoClient) async throws -> EODPriceResult {
    let activity = EODPriceActivities(db: db, tiingoClient: tiingo, logger: Logger(label: "test"))
    return try await activity.fetchAndUpsertEODPrices(runDate: Date())
}

// MARK: - Tests

@Suite("EODPriceActivity", .serialized)
struct EODPriceActivityTests {

    @Test("Fetches and upserts price for a single active equity")
    func singleEquityUpserted() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)
            mockTiingo(body: tiingoPriceJSON(close: 175.0))

            let result = try await runActivity(db: db, tiingo: tiingo)
            #expect(result.rowsUpserted == 1)
            #expect(result.failedTickers.isEmpty)
            #expect(result.instrumentsFetched == 1)
            #expect(result.source == "tiingo")

            let stored = try await EODPrice.query(on: db).all()
            #expect(stored.count == 1)
            #expect(stored[0].close == 175.0)
        }
    }

    @Test("Upsert is idempotent — running twice leaves one row")
    func upsertIdempotent() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)
            mockTiingo(body: tiingoPriceJSON(close: 175.0))
            _ = try await runActivity(db: db, tiingo: tiingo)

            mockTiingo(body: tiingoPriceJSON(close: 180.0))
            _ = try await runActivity(db: db, tiingo: tiingo)

            let stored = try await EODPrice.query(on: db).all()
            #expect(stored.count == 1)
            #expect(stored[0].close == 180.0)  // updated to latest value
        }
    }

    @Test("Inactive instruments are skipped")
    func inactiveInstrumentSkipped() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedInactiveEquity(ticker: "DEAD", db: db)
            mockTiingo(body: tiingoPriceJSON())

            let result = try await runActivity(db: db, tiingo: tiingo)
            #expect(result.instrumentsFetched == 0)
            #expect(result.rowsUpserted == 0)
        }
    }

    @Test("Tiingo error (non-401) is recorded as failedTicker, other instruments continue")
    func nonAuthErrorRecordedAsFailed() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "FAIL", db: db)
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)

            // Return 404 for FAIL, 200 for AAPL — but MockURLProtocol applies to all requests,
            // so we test with a single instrument failing
            nonisolated(unsafe) var callCount = 0
            MockTiingoURLProtocol.handler = { _ in
                callCount += 1
                if callCount == 1 {
                    return (Data("not found".utf8),
                            HTTPURLResponse(url: URL(string: "https://api.tiingo.com")!,
                                            statusCode: 404, httpVersion: nil, headerFields: nil)!)
                }
                return (tiingoPriceJSON(),
                        HTTPURLResponse(url: URL(string: "https://api.tiingo.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }

            let result = try await runActivity(db: db, tiingo: tiingo)
            #expect(result.failedTickers.count == 1)
            #expect(result.rowsUpserted == 1)
        }
    }

    @Test("Empty Tiingo response records ticker as failed")
    func emptyResponseFails() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)
            mockTiingo(body: Data("[]".utf8))  // noData thrown by TiingoKit

            let result = try await runActivity(db: db, tiingo: tiingo)
            #expect(result.failedTickers == ["AAPL"])
            #expect(result.rowsUpserted == 0)
        }
    }

    @Test("401 from Tiingo is rethrown and aborts the activity")
    func authErrorRethrown() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)
            mockTiingo(statusCode: 401, body: Data("unauthorized".utf8))

            do {
                _ = try await runActivity(db: db, tiingo: tiingo)
                Issue.record("Expected auth error to be thrown")
            } catch TiingoError.httpError(let code, _) {
                #expect(code == 401)
            }
        }
    }

    @Test("Multiple active instruments all upserted")
    func multipleInstruments() async throws {
        try await withEODDB { db, tiingo in
            _ = try await seedEquityInstrument(ticker: "AAPL", db: db)
            _ = try await seedEquityInstrument(ticker: "SPY",  db: db)
            _ = try await seedEquityInstrument(ticker: "MSFT", db: db)
            mockTiingo(body: tiingoPriceJSON())

            let result = try await runActivity(db: db, tiingo: tiingo)
            #expect(result.instrumentsFetched == 3)
            #expect(result.rowsUpserted == 3)
            #expect(result.failedTickers.isEmpty)
        }
    }
}
